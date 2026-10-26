-- 既存Aurora（demo-shared-db）に対して手動で実行する。
-- engineering/procurement スキーマは既存想定（フルEPCデモ側が使用中）のため
-- CREATE SCHEMA IF NOT EXISTS で既存スキーマに影響を与えず、テーブル名は
-- 既存の engineering_materials / procurement_materials と衝突しない materials にする。
--
-- 全体が冪等（何度実行しても同じ結果）になるように書いてあるので、
-- 案D→案Fへの拡張時も同じファイルを再実行すればよい。

CREATE SCHEMA IF NOT EXISTS engineering;
CREATE SCHEMA IF NOT EXISTS procurement;

-- ============================================================================
-- CDC のソース（案D・案F共通）
-- ============================================================================

CREATE TABLE IF NOT EXISTS engineering.materials (
  material_code varchar(32) PRIMARY KEY,
  material_name varchar(200) NOT NULL,
  quantity      numeric(12,2) NOT NULL,
  updated_at    timestamptz NOT NULL DEFAULT now()
);

INSERT INTO engineering.materials (material_code, material_name, quantity) VALUES
  ('MAT-001', 'H形鋼 300x300', 120),
  ('MAT-002', '鉄筋 D25',       500)
ON CONFLICT (material_code) DO NOTHING;

-- pgoutput プラグイン用の publication（Confluent Cloud フルマネージドコネクタが読み取る対象）。
-- ローカル版の mini_engineering_pub とは別名にして衝突を避ける。
-- CREATE PUBLICATION は IF NOT EXISTS 構文を持たないため DO ブロックで冪等化する。
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'mini_aws_engineering_pub') THEN
    CREATE PUBLICATION mini_aws_engineering_pub FOR TABLE engineering.materials;
  END IF;
END
$$;

-- ============================================================================
-- 案F: 承認フロー（案B相当）用テーブル
-- ============================================================================

-- 設計側の変更申請ワークフロー。CDC対象外（publication にも含めない）。
CREATE TABLE IF NOT EXISTS engineering.material_change_requests (
  request_id        SERIAL PRIMARY KEY,
  material_code     varchar(32) NOT NULL REFERENCES engineering.materials(material_code),
  new_material_name varchar(200),
  new_quantity      numeric(12,2),
  requested_by      varchar(100) NOT NULL,
  status            varchar(20) NOT NULL DEFAULT 'submitted'
                    CHECK (status IN ('submitted', 'approved', 'rejected')),
  requested_at      timestamptz NOT NULL DEFAULT now(),
  decided_by        varchar(100),
  decided_at        timestamptz
);

-- 調達側の取り込み承認用 staging。JDBC Sink Connector の書込先はこのテーブル。
-- （案D段階では procurement.materials に直接 upsert していたが、案Fでは承認を挟む）
--
-- カラム名は参照リポジトリ（reference-epc-demo）の
-- procurement.incoming_material_changes を踏襲して proposed_* にしている。
-- CDC イベント側のフィールド名は material_name / quantity なので、
-- Sink Connector 側で ReplaceField SMT による rename が必要。README の Step 6 参照。
--
-- CDC の updated_at（timestamptz）は Debezium が文字列（io.debezium.time.ZonedTimestamp）で
-- 出力し、JDBC Sink が timestamptz 列に setString して型エラーになるため、この staging には
-- 持たせず、Sink 側の fields.whitelist で捨てる。受信時刻は received_at の DEFAULT で埋める。
CREATE TABLE IF NOT EXISTS procurement.incoming_material_changes (
  change_id              SERIAL PRIMARY KEY,
  material_code          varchar(32) NOT NULL,
  proposed_material_name varchar(200) NOT NULL,
  proposed_quantity      numeric(12,2) NOT NULL,
  received_at            timestamptz NOT NULL DEFAULT now(),
  decision               varchar(20) NOT NULL DEFAULT 'pending'
                         CHECK (decision IN ('pending', 'accepted', 'declined')),
  decided_by             varchar(100),
  decided_at             timestamptz
);

-- 調達側の確定テーブル。案Dでは JDBC Sink の auto.create=true で自動生成させていたが、
-- 案Fでは Sink の書込先が staging に変わり誰も作らなくなるため、ここで明示的に作る。
-- Accept 時に procurement アプリが同一トランザクションで UPSERT する。
CREATE TABLE IF NOT EXISTS procurement.materials (
  material_code varchar(32) PRIMARY KEY,
  material_name varchar(200) NOT NULL,
  quantity      numeric(12,2) NOT NULL,
  updated_at    timestamptz NOT NULL DEFAULT now()
);
