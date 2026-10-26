import express from 'express';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Pool } from 'pg';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) {
  throw new Error('DATABASE_URL is required (postgres://user:password@host:5432/postgres)');
}

// ALB のパスベースルーティングは URL を書き換えない（ALB にパス rewrite 機能は無い）。
// つまり ALB 経由では /engineering/... というパスがそのままこのアプリに届く。
// そのため BASE_PATH を受け取り、アプリ全体をその prefix 配下にマウントする。
// ローカル実行では BASE_PATH 未設定 = ルート ("/") にマウントされる。
const BASE_PATH = (process.env.BASE_PATH || '').replace(/\/+$/, '');
const PORT = Number(process.env.PORT || 3101);

// Aurora は SSL 必須。デモなのでサーバ証明書の検証はしない（rds-ca の配布が別途必要になるため）。
const pool = new Pool({
  connectionString: DATABASE_URL,
  ssl: { rejectUnauthorized: false },
});

const indexHtmlPath = path.join(__dirname, 'public', 'index.html');

// BASE_PATH をブラウザ側に渡す。fetch を絶対パスで組み立てるため、
// ALB 経由（/engineering/api/...）でもローカル（/api/...）でも同じ HTML が動く。
function renderIndex() {
  return fs
    .readFileSync(indexHtmlPath, 'utf8')
    .replace('<!--BASE_PATH-->', `<script>window.__BASE_PATH__ = ${JSON.stringify(BASE_PATH)};</script>`);
}

const router = express.Router();

// ALB ターゲットグループのヘルスチェック先。ALB 側のパスは BASE_PATH 込みで
// /engineering/healthz を指定する（terraform-alb-s3/alb.tf 参照）。
router.get('/healthz', (req, res) => res.status(200).type('text/plain').send('ok'));

router.get('/', (req, res) => res.type('html').send(renderIndex()));

router.get('/api/materials', async (req, res, next) => {
  try {
    const { rows } = await pool.query(
      'SELECT material_code, material_name, quantity, updated_at FROM engineering.materials ORDER BY material_code'
    );
    res.json(rows);
  } catch (err) {
    next(err);
  }
});

router.get('/api/change-requests', async (req, res, next) => {
  try {
    const { rows } = await pool.query(
      'SELECT * FROM engineering.material_change_requests ORDER BY requested_at DESC, request_id DESC'
    );
    res.json(rows);
  } catch (err) {
    next(err);
  }
});

router.post('/api/change-requests', async (req, res, next) => {
  const { material_code, new_material_name, new_quantity, requested_by } = req.body ?? {};
  if (!material_code || !requested_by) {
    return res.status(400).json({ error: 'material_code and requested_by are required' });
  }
  if (!new_material_name && new_quantity === undefined) {
    return res.status(400).json({ error: 'new_material_name or new_quantity is required' });
  }
  try {
    const { rows } = await pool.query(
      `INSERT INTO engineering.material_change_requests
         (material_code, new_material_name, new_quantity, requested_by)
       VALUES ($1, $2, $3, $4)
       RETURNING *`,
      [material_code, new_material_name ?? null, new_quantity ?? null, requested_by]
    );
    res.status(201).json(rows[0]);
  } catch (err) {
    next(err);
  }
});

// 承認: material_change_requests を確定させ、engineering.materials を UPDATE する。
// この UPDATE が WAL に載り、CDC が発火する起点になる（デモの本体）。
router.post('/api/change-requests/:id/approve', async (req, res, next) => {
  const { id } = req.params;
  const { decided_by } = req.body ?? {};
  if (!decided_by) return res.status(400).json({ error: 'decided_by is required' });

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows: mcrRows } = await client.query(
      `UPDATE engineering.material_change_requests
       SET status = 'approved', decided_by = $2, decided_at = now()
       WHERE request_id = $1 AND status = 'submitted'
       RETURNING *`,
      [id, decided_by]
    );
    if (mcrRows.length === 0) {
      await client.query('ROLLBACK');
      return res.status(409).json({ error: 'not_submitted_or_missing' });
    }
    const mcr = mcrRows[0];
    await client.query(
      `UPDATE engineering.materials
       SET material_name = COALESCE($2, material_name),
           quantity      = COALESCE($3, quantity),
           updated_at    = now()
       WHERE material_code = $1`,
      [mcr.material_code, mcr.new_material_name, mcr.new_quantity]
    );
    await client.query('COMMIT');
    res.json(mcr);
  } catch (err) {
    await client.query('ROLLBACK');
    next(err);
  } finally {
    client.release();
  }
});

router.post('/api/change-requests/:id/reject', async (req, res, next) => {
  const { id } = req.params;
  const { decided_by } = req.body ?? {};
  if (!decided_by) return res.status(400).json({ error: 'decided_by is required' });
  try {
    const { rows } = await pool.query(
      `UPDATE engineering.material_change_requests
       SET status = 'rejected', decided_by = $2, decided_at = now()
       WHERE request_id = $1 AND status = 'submitted'
       RETURNING *`,
      [id, decided_by]
    );
    if (rows.length === 0) return res.status(409).json({ error: 'not_submitted_or_missing' });
    res.json(rows[0]);
  } catch (err) {
    next(err);
  }
});

const app = express();
app.use(express.json());
app.use(BASE_PATH || '/', router);

app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ error: 'internal_error', message: err.message });
});

app.listen(PORT, () => {
  console.log(`engineering app listening on :${PORT} (base path: "${BASE_PATH || '/'}")`);
});
