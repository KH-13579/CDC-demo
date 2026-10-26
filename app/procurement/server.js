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

// ALB のパスベースルーティングは URL を書き換えないため、ALB 経由では
// /procurement/... がそのままこのアプリに届く。BASE_PATH でその prefix 配下に
// アプリ全体をマウントする。ローカル実行では未設定 = ルート ("/")。
const BASE_PATH = (process.env.BASE_PATH || '').replace(/\/+$/, '');
const PORT = Number(process.env.PORT || 3102);

// Aurora は SSL 必須。デモなのでサーバ証明書の検証はしない（rds-ca の配布が別途必要になるため）。
const pool = new Pool({
  connectionString: DATABASE_URL,
  ssl: { rejectUnauthorized: false },
});

const indexHtmlPath = path.join(__dirname, 'public', 'index.html');

function renderIndex() {
  return fs
    .readFileSync(indexHtmlPath, 'utf8')
    .replace('<!--BASE_PATH-->', `<script>window.__BASE_PATH__ = ${JSON.stringify(BASE_PATH)};</script>`);
}

const router = express.Router();

// ALB ターゲットグループのヘルスチェック先（ALB 側は /procurement/healthz を指定）。
router.get('/healthz', (req, res) => res.status(200).type('text/plain').send('ok'));

router.get('/', (req, res) => res.type('html').send(renderIndex()));

// JDBC Sink Connector が書き込んだ staging の一覧。?decision=pending で絞り込める。
router.get('/api/incoming-changes', async (req, res, next) => {
  const { decision } = req.query;
  try {
    const params = [];
    let sql = 'SELECT * FROM procurement.incoming_material_changes';
    if (decision) {
      sql += ' WHERE decision = $1';
      params.push(decision);
    }
    sql += ' ORDER BY received_at DESC, change_id DESC LIMIT 100';
    const { rows } = await pool.query(sql, params);
    res.json(rows);
  } catch (err) {
    next(err);
  }
});

router.get('/api/materials', async (req, res, next) => {
  try {
    const { rows } = await pool.query(
      'SELECT material_code, material_name, quantity, updated_at FROM procurement.materials ORDER BY material_code'
    );
    res.json(rows);
  } catch (err) {
    next(err);
  }
});

// 取り込み承認: staging の確定 → procurement.materials への UPSERT を同一トランザクションで行う。
// 参照リポジトリ apps/procurement/api/src/routes/incoming-changes.js と同じパターン。
router.post('/api/incoming-changes/:id/accept', async (req, res, next) => {
  const { id } = req.params;
  const { decided_by } = req.body ?? {};
  if (!decided_by) return res.status(400).json({ error: 'decided_by is required' });

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows: imcRows } = await client.query(
      `UPDATE procurement.incoming_material_changes
       SET decision = 'accepted', decided_by = $2, decided_at = now()
       WHERE change_id = $1 AND decision = 'pending'
       RETURNING *`,
      [id, decided_by]
    );
    if (imcRows.length === 0) {
      await client.query('ROLLBACK');
      return res.status(409).json({ error: 'not_pending_or_missing' });
    }
    const imc = imcRows[0];
    await client.query(
      `INSERT INTO procurement.materials (material_code, material_name, quantity, updated_at)
       VALUES ($1, $2, $3, now())
       ON CONFLICT (material_code) DO UPDATE
         SET material_name = EXCLUDED.material_name,
             quantity      = EXCLUDED.quantity,
             updated_at    = now()`,
      [imc.material_code, imc.proposed_material_name, imc.proposed_quantity]
    );
    await client.query('COMMIT');
    res.json(imc);
  } catch (err) {
    await client.query('ROLLBACK');
    next(err);
  } finally {
    client.release();
  }
});

router.post('/api/incoming-changes/:id/decline', async (req, res, next) => {
  const { id } = req.params;
  const { decided_by } = req.body ?? {};
  if (!decided_by) return res.status(400).json({ error: 'decided_by is required' });
  try {
    const { rows } = await pool.query(
      `UPDATE procurement.incoming_material_changes
       SET decision = 'declined', decided_by = $2, decided_at = now()
       WHERE change_id = $1 AND decision = 'pending'
       RETURNING *`,
      [id, decided_by]
    );
    if (rows.length === 0) return res.status(409).json({ error: 'not_pending_or_missing' });
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
  console.log(`procurement app listening on :${PORT} (base path: "${BASE_PATH || '/'}")`);
});
