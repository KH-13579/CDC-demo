# mini-cdc-demo AWS版（案F: 承認フロー + ALB + S3 Sink）

ローカル版（`../README.md`）はセルフホストの Kafka Connect を自分の PC で動かしていたが、
AWS版では既存の共有 Aurora（`demo-shared-db`、詳細は 構築メモ（非公開））を使い、
Confluent Cloud の**フルマネージドコネクタ**が直接 Aurora に到達する構成にする。
セルフホスト Kafka Connect は不要になる。

さらに、CDC の基本原理だけでなく**業務ガバナンス（申請 → 承認 → 連携 → 取り込み承認）**を
再現するため、参照リポジトリ（`reference-epc-demo`）と同じ staging テーブル方式にしている。

```
[engineering アプリ]  変更申請 → 承認ボタン
   │                                  (承認が CDC の発火点)
   ├─ engineering.material_change_requests  (申請ワークフロー。CDC対象外)
   ▼
engineering.materials (Aurora)
   │ WAL (logical replication / pgoutput)
   ▼
Confluent Cloud  Postgres CDC Source Connector (フルマネージド)
   │
   ├─ Kafka topic: mini_aws.engineering.materials ─▶ S3 Sink Connector ─▶ S3 バケット(アーカイブ)
   ▼
Confluent Cloud  Postgres Sink Connector (フルマネージド)
   │  ReplaceField SMT でカラム名を staging に合わせる
   ▼
procurement.incoming_material_changes (staging / 取り込み待ち)
   │
   ▼  [procurement アプリ]  Accept ボタン（同一トランザクションで UPSERT）
procurement.materials (調達側の確定データ)
```

ブラウザからのアクセスは EC2 上の 2 プロセス（3101 / 3102）に、
ミニデモ専用の新規 ALB がパスベースルーティングで振り分ける。

```
ブラウザ ─▶ ALB:80 ─┬─ /engineering* ─▶ EC2:3101 (systemd: mini-engineering)
                    └─ /procurement* ─▶ EC2:3102 (systemd: mini-procurement)
```

## ディレクトリ

| パス | 内容 |
|---|---|
| `init-aurora.sql` | Aurora に作るテーブル・publication（冪等。何度実行してもよい） |
| `app/engineering/` | 設計側アプリ（Node/Express、ビルド不要） |
| `app/procurement/` | 調達側アプリ（Node/Express、ビルド不要） |
| `systemd/` | EC2 常駐用の systemd ユニットと環境変数ファイルの雛形 |
| `terraform/` | **案D分**: Aurora の Security Group へのルール追加のみ。デモ期間中は apply したままにする |
| `terraform-alb-s3/` | **案F分**: ALB + S3 バケット + IAM Role（Provider Integration 用）。**時間課金があるので検証時だけ apply して destroy する** |
| 構築メモ（非公開） | 既存 AWS 環境の構築記録（git 管理外。パスワードを含む） |

`terraform/` と `terraform-alb-s3/` で state を分けているのは、ALB を destroy しても
Aurora の SG ルール（= CDC の通り道）が消えないようにするため。

---

## GUI（手作業）が必要な手順の一覧

「CLI 代替」が ○ の行は自動化できるので、
GUI を触って概念を掴む目的が済んだら CLI に寄せてよい。

### AWS マネジメントコンソール

| # | 画面 | やること | CLI代替 | Step |
|---|---|---|---|---|
| A1 | RDS → パラメータグループ → 新規作成 | 既存が `default.*`（編集不可）のため、カスタムパラメータグループを作成し `rds.logical_replication=1` を設定（**ここまでは無料・既存クラスターへ影響なし**） | ○ | 0-2 |
| A2 | RDS → クラスター → 変更 → アクション | 作成したパラメータグループへの**関連付け**＋**再起動**（静的パラメータの反映に必須）。共有クラスターなので**事前にチーム合意が必須** | ○ | 0-2 |
| A3 | RDS → インスタンス → 変更 | `PubliclyAccessible` を `true` に変更（**要チーム/管理者確認**） | ○ | 0-2 |
| A4 | EC2 → インスタンス / サブネット / ルートテーブル | ALB 用に「別 AZ の 2 サブネット」とそのパブリック性を確認 | ○ | 0-3 |
| A5 | EC2 → Instance Connect / Systems Manager | EC2 にログインして Node.js・アプリ・systemd を配置する（**この作業自体はシェル操作**） | △ | 7 |
| A6 | S3 → オブジェクト → 「署名付き URL で共有」 | EC2 にファイルを渡すための URL 発行（EC2 がインターネットに出られないため） | ○ | 7-2 |
| A7 | EC2 → ターゲットグループ | ヘルスステータスが healthy になったか確認（unhealthy 時の切り分けもここ） | ○ | 8 |
| A8 | S3 → バケット | Sink がアーカイブしたオブジェクトが増えたか確認 | ○ | 9 |

> A1〜A3 が**このデモ全体の絶対前提**。ここが通らないと Confluent Cloud の
> フルマネージドコネクタ方式そのものが成立しない（Step 0-2 の警告を参照）。
> A4〜A8 は Terraform / AWS CLI でも確認できるが、**AWS の構成要素を体で理解する**という
> 今回の目的では一度コンソールで見ておく価値がある。

### Confluent Cloud（すべて GUI。このデモでは Terraform 管理しない）

| # | 画面 | やること | Step |
|---|---|---|---|
| C1 | Environments → Add environment | Environment 作成 + Stream Governance（Schema Registry）有効化。**AVRO を使うので必須** | 4 |
| C2 | Clusters → Create cluster | **Basic** クラスター作成（AWS / **ap-northeast-1**。S3 バケットと同リージョンにする） | 4 |
| C3 | Cluster settings → Networking | **Egress IP リスト**を取得 → `terraform/terraform.tfvars` の `confluent_egress_cidrs` に転記して apply | 4 |
| C4 | Connectors → Postgres CDC Source V2 | ソースコネクタ作成。slot / publication 名、`after.state.only`、`decimal.handling.mode`、`heartbeat.interval.ms` がポイント | 5 |
| C5 | Topics → Messages | topic にイベントが流れたか確認（CDC が動いた証拠） | 5 |
| C6 | Connectors → Postgres Sink | Sink コネクタ作成。**`ReplaceField` SMT と `fields.whitelist` の設定が最大のハマりどころ** | 6 |
| C7 | Environment → Provider Integrations → Add integration (AWS) | 作成予定の IAM Role ARN を入力 → 提示された trust policy の Principal / External ID を `terraform-alb-s3/terraform.tfvars` に設定して apply → 画面に戻って完了させる | 8 |
| C8 | Connectors → Amazon S3 Sink | S3 Sink 作成。Authentication method に **IAM Roles**（C7 で作成した Provider Integration）を選択。Access Key の入力は不要。**`rotate.schedule.interval.ms`（画面名 Maximum span of record time ... before scheduled rotation）を設定しないと S3 に何も出ない**（Flush size は下限があり小さくできない） | 9 |
| C9 | Connectors → 各コネクタ → Delete | 後片付け。**コネクタを削除しないと replication slot が消せない** | 後片付け |

参照リポジトリには Confluent Cloud 側の IaC（`infra/confluent/terraform/`）もあるので、
GUI で一度作って理解したあと、そちらを読むと「この画面のこの項目がこの設定キー」が対応づけられる。

### コマンドで完結する作業（GUI 不要）

- `init-aurora.sql` の実行（psql）
- Aurora SG へのルール追加（`terraform/`）
- ALB・S3 バケット・IAM Role の作成（`terraform-alb-s3/`）
- EC2 上の Node.js / アプリ配置 / systemd 登録（Step 7 のシェル手順）
- replication slot と publication の削除（psql）

---

## Step 0. 前提確認

### 0-1. AWS 認証

組織の規約で IAM アクセスキーは新規作成できないので、`aws configure` にキーを入れる方式は使わない。
代わりに AWS CLI v2 の `aws login` で、**コンソールのログインセッション（MFA 済み）から
一時認証情報を発行**する。ブラウザが開くので、いつもどおりコンソールにサインインする。

```powershell
aws login --region ap-northeast-1
aws sts get-caller-identity     # Account / Arn が返れば OK
terraform -version
```

一時認証情報は期限付き（CLI が自動更新する）。期限切れ・更新失敗のエラーが出たら `aws login` をやり直す。

> Terraform が `No valid credential sources found` になる場合は、AWS プロバイダが `aws login` の
> 認証情報をまだ読めていない。CLI から一時認証情報を環境変数に書き出して渡す:
>
> ```powershell
> aws configure export-credentials --format powershell | Invoke-Expression
> ```
>
> Git Bash なら `eval "$(aws configure export-credentials --format env)"`。
> 環境変数に入れた値は自動更新されないので、期限が切れたら再実行する。
>
> **注意**: 環境変数は `aws login` のキャッシュより優先される。期限切れの環境変数が残ったシェルでは、
> `aws login` し直しても AWS CLI が `Credentials were refreshed, but the refreshed credentials are still expired`
> で失敗する（権限の問題ではない）。その場合は環境変数を消すか、新しいターミナルを開く:
>
> ```bash
> unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION
> ```

### 0-2. Aurora の設定確認

```bash
# クラスターの状態・エンドポイント・SG・パラメータグループ
aws rds describe-db-clusters --db-cluster-identifier demo-shared-db \
  --query 'DBClusters[0].[Endpoint,Status,DBClusterParameterGroup,VpcSecurityGroups[].VpcSecurityGroupId]'

# publicly_accessible はインスタンス側の属性
aws rds describe-db-instances \
  --query 'DBInstances[?DBClusterIdentifier==`demo-shared-db`].[DBInstanceIdentifier,PubliclyAccessible]'

# rds.logical_replication の現在値
aws rds describe-db-cluster-parameters \
  --db-cluster-parameter-group-name <上で取得したパラメータグループ名> \
  --query 'Parameters[?ParameterName==`rds.logical_replication`].[ParameterValue,ApplyType]'
```

確認するもの:

- [ ] `rds.logical_replication` が `1` か（`0` なら CDC は動かない）
- [ ] `PubliclyAccessible` が `true` か（`false` だとフルマネージドコネクタが到達できない）
- [ ] Aurora が実際に使っている Security Group ID → `terraform/terraform.tfvars` の `aurora_security_group_id`
- [ ] Aurora のエンドポイント（`...cluster-xxxxxxxxxxxx.ap-northeast-1.rds.amazonaws.com` 形式。実値は 構築メモ（非公開） にある）
- [ ] パラメータグループ名が **`default.` で始まっていないか**（下記参照）

> **重要: `DBClusterParameterGroup` が `default.aurora-postgresqlNN` の場合、直接編集できない**
> （AWS 管理のデフォルトグループは変更を拒否する）。`rds.logical_replication` を変更するには、
> 先に**カスタムのクラスターパラメータグループを作って関連付ける**必要がある
> （参照リポジトリの `infra/aws/terraform/aurora.tf` も同じ理由で作っている）。

```bash
# 1. カスタムパラメータグループを作成（無料・既存クラスターに影響なし。作るだけなら何度でも安全）
aws rds create-db-cluster-parameter-group \
  --db-cluster-parameter-group-name demo-shared-db-pg \
  --db-parameter-group-family aurora-postgresql17 \
  --description "mini-cdc-demo: rds.logical_replication=1"

# 2. パラメータを設定（この時点でも既存クラスターにはまだ効果なし。グループ単体の設定変更）
aws rds modify-db-cluster-parameter-group \
  --db-cluster-parameter-group-name demo-shared-db-pg \
  --parameters "ParameterName=rds.logical_replication,ParameterValue=1,ApplyMethod=pending-reboot"
```


```bash
# 3. クラスターに関連付け（この時点で Modifying 状態になる。適用は次の再起動時）
aws rds modify-db-cluster \
  --db-cluster-identifier demo-shared-db \
  --db-cluster-parameter-group-name demo-shared-db-pg \
  --apply-immediately

# 4. 再起動（rds.logical_replication の反映に必須）
# Aurora はクラスター単位の reboot-db-cluster が使えない（Multi-AZ DB クラスター機能専用のAPI）。
# インスタンス単位の reboot-db-instance を使う。
aws rds reboot-db-instance --db-instance-identifier demo-shared-db-instance-1
```
>   ```bash
>   aws rds modify-db-instance --db-instance-identifier demo-shared-db-instance-1 \
>     --publicly-accessible --apply-immediately
>   ```

### 0-3. EC2 / VPC の確認（ALB 用）

```bash
aws ec2 describe-instances --instance-ids i-0123456789abcdef0 \
  --query 'Reservations[0].Instances[0].[InstanceId,VpcId,SubnetId,PrivateIpAddress,State.Name,SecurityGroups]'

# ALB 用サブネット候補（AZ とパブリック性を確認する）
aws ec2 describe-subnets --filters Name=vpc-id,Values=<VpcId> \
  --query 'Subnets[].[SubnetId,AvailabilityZone,MapPublicIpOnLaunch,Tags[?Key==`Name`].Value|[0]]' --output table
```

確認するもの:

- [ ] EC2 のインスタンス ID / VPC ID / **実際に使っている Security Group ID**
- [ ] **異なる AZ に 2 つ以上のサブネット**があるか（ALB の必須条件）
- [ ] そのサブネットが Internet Gateway へのルートを持つか（インターネット向け ALB の条件）
      → `aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=<SubnetId>` で
      `0.0.0.0/0 → igw-...` があるか確認


### 0-4. 既存スキーマの確認（既存データに影響しないことの確認）

> **前提**: このコマンドは Aurora に到達できる必要がある。`PubliclyAccessible=true` に
> なっていて、かつ自分の PC の IP が Aurora の SG に許可されている（Step 2 の
> `developer_cidrs`）ことが条件。**まだの場合は先に Step 2 まで進めてから戻ってくる**
> （SG を触りたくない場合は EC2 に入って EC2 上から実行してもよい）。

```bash
psql "host=<Auroraエンドポイント> port=5432 dbname=postgres user=postgres sslmode=require" \
  -c "\dn" -c "\dt engineering.*" -c "\dt procurement.*"
```

> `psql` が手元に無い場合、Docker で代用できる（インストール不要）:
> ```bash
> docker run --rm -it postgres:16 psql \
>   "host=<Auroraエンドポイント> port=5432 dbname=postgres user=postgres sslmode=require" \
>   -c "\dn" -c "\dt engineering.*" -c "\dt procurement.*"
> ```

`engineering.materials` / `procurement.materials` / `procurement.incoming_material_changes` が
**まだ無い**ことを確認する（フル EPC デモは `engineering_materials` のようにアンダースコア名を
使っているので衝突しない想定）。

### 0-5. IAM 権限の確認（S3 Sink 用）

S3 Sink の認証には **IAM Role + Confluent Provider Integration** を使う（IAM User + Access Key は
使わない）。

このため `terraform-alb-s3/` は IAM Role・IAM Policy（inline）を新規作成する。
IAM ロール/ポリシーの作成には次の2つが必須:

- 名前の先頭に「申請ID」を付与（このリポジトリでは既存の共有リソースと同じ
  `example-org` を使用。`terraform-alb-s3/main.tf` の `local.org_prefix`）
- 「許可の境界」として `OrgPermissionBoundary` ポリシーを指定
  （`terraform-alb-s3/s3.tf` の `data.aws_iam_policy.permission_boundary` が検索する）

```bash
aws iam get-user
aws iam get-policy --policy-arn arn:aws:iam::<アカウントID>:policy/OrgPermissionBoundary
```

`OrgPermissionBoundary` が存在しない/見えない場合や、Step 8 の `terraform apply` が


なお Confluent は PassRole の許可対象（EC2/Lambda/ECS Task/EKS/EventBridge Scheduler/EFS）
のいずれでもない。クロスアカウントの `sts:AssumeRole` で完結する。

---

## Step 1. Aurora にテーブル作成

自分の PC から psql で流すには、先に Aurora の SG に自分のグローバル IP を許可する必要がある
（Step 2 の `developer_cidrs`）。SG を触りたくない場合は EC2 に入って EC2 上から実行してもよい。

```bash
psql "host=<Auroraエンドポイント> port=5432 dbname=postgres user=postgres sslmode=require" -f init-aurora.sql
```

> `psql` が無い場合、Docker で代用できる（`aws/` ディレクトリで実行。ファイルは標準入力で渡す
> のでボリュームマウント不要）:
> ```bash
> read -s -p "Aurora password: " PGPASSWORD; echo; export PGPASSWORD
> docker run --rm -i -e PGPASSWORD postgres:16 psql \
>   "host=<Auroraエンドポイント> port=5432 dbname=postgres user=postgres sslmode=require" \
>   -v ON_ERROR_STOP=1 < init-aurora.sql
> ```
>
> パスワードは必ず `PGPASSWORD` で渡す。`-t` なし（標準入力に SQL を流している）だと psql は
> パスワードを標準入力から読むため、**SQL ファイルの1行目がパスワードとして送られて**
> `password authentication failed` になる。

作られるもの:

| オブジェクト | 役割 |
|---|---|
| `engineering.materials` | CDC のソース。承認時に UPDATE される |
| `engineering.material_change_requests` | 申請ワークフロー（CDC 対象外） |
| `procurement.incoming_material_changes` | Postgres Sink の書込先 staging |
| `procurement.materials` | 調達側の確定データ（Accept 時に UPSERT） |
| `mini_aws_engineering_pub` | publication（`engineering.materials` のみ） |

確認:

```sql
SELECT * FROM pg_publication_tables WHERE pubname = 'mini_aws_engineering_pub';
```

## Step 2. Terraform（Aurora の SG にルール追加のみ）

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars を編集:
#   aurora_security_group_id … Step 0-2 で確認した SG ID
#   developer_cidrs          … 自分のグローバル IP（curl https://checkip.amazonaws.com/）
#   confluent_egress_cidrs   … まだ [] のままでよい（Step 4 で追記する）

terraform init
terraform plan    # 「追加されるルールが N 件だけ」であることを確認する
terraform apply
```

`aws_security_group`（SG 本体）ではなく `aws_vpc_security_group_ingress_rule`（個別ルール）を
使っているので、**既存の他のルールには一切影響しない**。

> 既に手作業で同じ CIDR / ポートのルールを追加していると `InvalidPermission.Duplicate` になる。
> その場合はコンソール側の重複ルールを消してから apply する。

## Step 3. ローカルでアプリの動作確認

CDC 以外の部分（申請 → 承認 → Accept → 確定）を先に通しておくと、
あとで CDC が動かないときの切り分けが楽になる。

自分の PC でアプリを起動して Aurora に向ける（Step 2 の `developer_cidrs` が必要）。

`DATABASE_URL` はURL形式なので、パスワードに `?` `@` `:` `/` `%` などの記号が含まれていると
区切り文字と誤認識されて壊れる（構築メモ（非公開） のパスワードはこれに該当する）。
bash だけでパーセントエンコードしてから埋め込む（環境によっては `node` をパイプ/変数キャプチャで
使うとブロックされることがあるため、外部コマンドに依存しない方法にしている）:

```bash
urlencode() { local s="$1" out= c i; for ((i=0; i<${#s}; i++)); do c="${s:i:1}"; case "$c" in [a-zA-Z0-9.~_-]) out+="$c";; *) printf -v h '%%%02X' "'$c"; out+="$h";; esac; done; printf '%s' "$out"; }
read -s -p "Aurora password: " PGPASS; echo
ENC=$(urlencode "$PGPASS")
export DATABASE_URL="postgres://postgres:${ENC}@<Auroraエンドポイント>:5432/postgres"
unset PGPASS ENC

cd app/engineering && npm install && node server.js   # http://localhost:3101/
# 別ターミナルで（上の urlencode 定義〜export をもう一度実行してから）
cd app/procurement && npm install && node server.js   # http://localhost:3102/
```

PowerShell を使う場合:
```powershell
$sec = Read-Host -AsSecureString "Aurora password"
$plain = [System.Net.NetworkCredential]::new('', $sec).Password
$env:DATABASE_URL = "postgres://postgres:$([uri]::EscapeDataString($plain))@<Auroraエンドポイント>:5432/postgres"
```

`BASE_PATH` 未設定ならルート（`/`）にマウントされるので、ローカルではそのまま開ける
（`BASE_PATH` は Step 8 の ALB 経由アクセス専用）。

### 確認すること

1. engineering 画面で MAT-001 の quantity を変える申請を出す → 申請一覧に `submitted` で出る
2. 「承認」を押す → `approved` になり、**資材一覧の quantity も変わる**（← ここが CDC の発火点）
3. この時点では procurement 画面の受信一覧は空（コネクタが無いので当然）
4. Sink Connector が書き込む INSERT を手で再現して Accept を試す
   （Step 6 の `fields.whitelist` に合わせて 3 列だけを入れる。残りは DEFAULT で埋まる）:

   ```sql
   INSERT INTO procurement.incoming_material_changes
     (material_code, proposed_material_name, proposed_quantity)
   VALUES ('MAT-001', 'H形鋼 300x300', 777);
   ```

   → procurement 画面に `pending` で出る → Accept → `procurement.materials` に反映される
5. もう一度 Accept を押すと `409`（二重承認されない）、Decline した行は
   `procurement.materials` に反映されない

## Step 4. Confluent Cloud の準備（UI 操作）

1. Environment 作成 → **Basic** クラスター作成（Provider: AWS / Region: **ap-northeast-1**）
   - S3 バケットと同じリージョンにする（S3 Sink の要件）
2. Schema Registry を有効化（Stream Governance Essentials。AVRO を使うので必要）
3. **Cluster Settings > Networking** で **Egress IP リスト**を取得
   → `terraform/terraform.tfvars` の `confluent_egress_cidrs` に `/32` 形式で追記して `terraform apply`
   eval "$(aws configure export-credentials --format env)"
   terraform plan
   terraform apply

## Step 5. Postgres CDC Source Connector（UI 操作）

**Connectors → Add connector → Postgres CDC Source V2 (Debezium)**

| 設定 | 値 | 理由 |
|---|---|---|
| Kafka credentials | Service account（新規作成）または My account |  |
| Database hostname / port | Aurora エンドポイント / `5432` | |
| Database username / password | `postgres` / 構築メモ（非公開） のパスワード | |
| Database name | `postgres` | |
| SSL mode | `require` | Aurora は SSL 必須 |
| Topic prefix | `mini_aws` | topic 名が `mini_aws.engineering.materials` になる |
| Tables included | `engineering.materials` | **空欄だと全テーブルが対象**になり、他メンバーの `engineering_materials` まで topic に流れる |
| Output Kafka record value format | `AVRO` | 参照リポジトリと同じ。Schema Registry を使う |
| Output Kafka record key format | `AVRO` | 参照リポジトリと同じ |
| Slot name | `mini_aws_engineering_slot` | 既定の `debezium` から変更。共有 Aurora 上で誰の slot か分かるように |
| Publication name | `mini_aws_engineering_pub` | 既定の `dbz_publication` から変更。Step 1 で作成済み |
| Snapshot mode | `initial`（既定） | 起動時に既存行（MAT-001/002）を1回流す。Sink 作成後、procurement 画面に `pending` が2件出るのはこのため |

以下は **「Show advanced configurations」を開くと出てくる**項目（作成後は Settings → Advanced configuration → Edit）:

| 設定 | 値 | 理由 |
|---|---|---|
| Publication auto-create mode | `disabled` | 既定の `all_tables` だと、共有 Aurora に**全テーブル対象の publication を勝手に作る** |
| After-state only | `true` | 既定の `false` だと before/after/op の envelope 形式で流れ、Step 6 の Sink の SMT が効かず失敗する |
| Decimal handling mode | `double` | 既定の `precise` だと `quantity` が base64 で表示されて読めない |
| Heartbeat interval (ms) | `0`（既定のまま） | 本来は `30000` にしてアイドル時も slot を進めたいが、heartbeat 用 topic のスキーマ登録で失敗した（`could not register a schema for topic __debezium-heartbeat-...`）ため `0` にしている。**その代わり WAL が溜まるので、デモが終わったらすぐコネクタと slot を削除する** |

> **既定値のまま作ってしまった場合**: Settings から上の値に Edit で直したあと、
> Aurora に残った既定名の slot / publication を消す（残すと WAL が溜まり続ける）。
> `rds.logical_replication` を有効化する前は他の人が logical slot を作れないので、
> `debezium` / `dbz_publication` はこのコネクタが作ったものと判断してよい（念のため確認してから消す）:
>
> ```sql
> SELECT slot_name, plugin, active FROM pg_replication_slots;
> SELECT pubname, puballtables FROM pg_publication;
> -- debezium が active = false になってから
> SELECT pg_drop_replication_slot('debezium');
> DROP PUBLICATION dbz_publication;
> ```


`Running` になったら **Topics → `mini_aws.engineering.materials` → Messages** を開き、
engineering 画面で承認を 1 回実行してイベントが流れることを確認する。

## Step 6. Postgres Sink Connector（UI 操作）

**Connectors → Add connector → Postgres Sink**

| 設定 | 値 |
|---|---|
| Topics | `mini_aws.engineering.materials`（これ1つだけにチェック） |
| Kafka credentials | Step 5 と同じ方式 |
| Input Kafka record value format | `AVRO` |
| Input Kafka record key format | `AVRO`（Step 5 の output key format に合わせる） |
| Connection host / port | Aurora エンドポイント / `5432` |
| Connection user / password | `postgres` / パスワード |
| Database name | `postgres` |
| SSL mode | `require` |
| DB timezone | `Asia/Tokyo` |
| Insert mode | `INSERT` |
| Table name format | `procurement.incoming_material_changes` |
| Auto create / Auto evolve | **`false` / `false`** |
| Delete enabled | `false` |
| PK mode | `none`（既定） |
| Errors tolerance | **`none`**（既定は `all`） |

上の表のうち、最初の画面に見当たらない項目は「**Show advanced configurations**」の中にある。
`Errors tolerance` を既定の `all` のままにすると、書き込み失敗は DLQ topic に回されるだけで
コネクタは Running のまま＝「動いているのにデータが来ない」状態になり原因に気づけない。

SMT はコネクタ作成画面の **Transforms → Add SMT** から 1 つ追加する:

```
transforms                      = renameFields
transforms.renameFields.type    = org.apache.kafka.connect.transforms.ReplaceField$Value
transforms.renameFields.include = material_code,material_name,quantity
transforms.renameFields.renames = material_name:proposed_material_name,quantity:proposed_quantity
```

> `include` には**変更前**の名前を書く（ReplaceField は「絞り込み → rename」の順に処理する）。
> 参照リポジトリは Terraform で `fields.whitelist`（Sink 側の設定）を使っているが、UI には出てこない
> ことがあるため、ここでは SMT の `include` で同じ絞り込みをしている。

> **なぜ SMT が必要か（ここでハマる）**
> - CDC イベントのフィールド名は `material_name` / `quantity` だが、staging の列名は
>   `proposed_material_name` / `proposed_quantity`。名前が一致しないと書き込めない。
>   参照リポジトリも同じ理由で `ReplaceField$Value` を使っている
>   （`infra/confluent/terraform/connectors.tf`）。
> - `updated_at` は Debezium が `io.debezium.time.ZonedTimestamp` = **文字列**で出すため、
>   `timestamptz` 列に文字列を挿す形になり型エラーになる。SMT の `include` で捨てる。
>   staging の `received_at` は `DEFAULT now()` で埋まる。
> - `include` に列挙した以外のフィールドは全部落ちるので、想定外のフィールド
>   （`__deleted` など）が増えても勝手に落ちてくれる。
> - `auto.evolve` を `true` にすると、名前の合わない `material_name` 列が staging に
>   ALTER TABLE で足され、NOT NULL の `proposed_*` が埋まらず INSERT が失敗する。**必ず false。**

これで engineering 画面の「承認」→ 数秒後に procurement 画面の受信一覧に行が現れる。
Accept を押すと `procurement.materials` に反映される。

## Step 7. EC2 へのデプロイ

EC2（Ubuntu 26.04, `i-0123456789abcdef0`）は**インターネットに出られない**
（構築メモ（非公開） に `changelogs.ubuntu.com` への到達失敗の記録あり）。
`apt install` も `npm install` も EC2 上ではできないので、
**ローカルで用意して S3 経由の署名付き URL で持ち込む**（構築メモ（非公開） の Docker/nginx 導入と同じ方法）。

### 7-1. ローカルで持ち込みアーカイブを作る

```bash
# Node.js 本体（公式ビルド）をダウンロード
curl -LO https://nodejs.org/dist/v22.20.0/node-v22.20.0-linux-x64.tar.xz

# 依存を取得（express / pg は純 JS なので Windows で入れたものが Linux でもそのまま動く）
cd app/engineering && npm install --omit=dev && cd ../..
cd app/procurement && npm install --omit=dev && cd ../..

# アプリ + systemd ユニットをまとめる
tar czf mini-cdc-app.tar.gz app systemd
sha256sum node-v22.20.0-linux-x64.tar.xz mini-cdc-app.tar.gz
```

### 7-2. S3 経由で EC2 に渡す

```bash
aws s3 cp node-v22.20.0-linux-x64.tar.xz s3://<既存バケット>/mini-cdc-demo/
aws s3 cp mini-cdc-app.tar.gz            s3://<既存バケット>/mini-cdc-demo/

aws s3 presign s3://<既存バケット>/mini-cdc-demo/node-v22.20.0-linux-x64.tar.xz --expires-in 3600
aws s3 presign s3://<既存バケット>/mini-cdc-demo/mini-cdc-app.tar.gz --expires-in 3600
```

> **署名付き URL は実質約15分で失効する**。`--expires-in 3600` と指定しても、署名に使った
> `aws login` の一時認証情報（約15分）が切れた時点で `ExpiredToken` になる。
> presign の直前に `aws sts get-caller-identity` で認証情報を更新し、**発行したらすぐ EC2 で curl する**。
> 失敗すると 1KB 程度のエラー XML が保存されるので、`ls -l` でサイズを確認する。

EC2 側で実行する。AWS コンソール → EC2 → インスタンス → 接続 → **Session Manager** タブ → 接続
（既定の「EC2 Instance Connect」は EC2 にパブリック IP が無いので使えない）。
最初は `ssm-user` なので `sudo -u ubuntu -i` してから:

```bash
cd /tmp
curl -o node.tar.xz "<署名付きURL1>"
curl -o mini-cdc-app.tar.gz "<署名付きURL2>"
sha256sum node.tar.xz mini-cdc-app.tar.gz   # ローカルの値と一致するか
```

### 7-3. Node.js の配置

```bash
sudo tar -xJf /tmp/node.tar.xz -C /opt
sudo ln -sf /opt/node-v22.20.0-linux-x64/bin/node /usr/local/bin/node
node -v    # v22.20.0
```

### 7-4. アプリの配置

```bash
sudo tar xzf /tmp/mini-cdc-app.tar.gz -C /tmp
sudo mkdir -p /opt/mini-cdc-demo
sudo cp -r /tmp/app/engineering /opt/mini-cdc-demo/engineering
sudo cp -r /tmp/app/procurement /opt/mini-cdc-demo/procurement
sudo chown -R ubuntu:ubuntu /opt/mini-cdc-demo
```

### 7-5. 環境変数と systemd

```bash
sudo mkdir -p /etc/mini-cdc-demo

sudo cp /tmp/systemd/engineering.env.example /etc/mini-cdc-demo/engineering.env
sudo cp /tmp/systemd/procurement.env.example /etc/mini-cdc-demo/procurement.env
sudo chmod 600 /etc/mini-cdc-demo/*.env

# <AURORA_ENDPOINT> と <AURORA_PASSWORD> を実値に置き換える。
# パスワードは記号を含むので URL エンコードが必須。画面・履歴に残さないよう read -s で受け取る
sudo sed -i "s|<AURORA_ENDPOINT>|<Auroraエンドポイント>|" /etc/mini-cdc-demo/*.env
read -s -p "Aurora password: " P; echo
ENC=$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$P")
sudo sed -i "s|<AURORA_PASSWORD>|$ENC|" /etc/mini-cdc-demo/*.env
unset P ENC

# 確認（パスワード部分は伏せて表示）
sudo sed -E 's#(postgres://[^:]+:)[^@]*@#\1****@#' /etc/mini-cdc-demo/*.env

sudo cp /tmp/systemd/mini-engineering.service /etc/systemd/system/
sudo cp /tmp/systemd/mini-procurement.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mini-engineering mini-procurement
sudo systemctl status mini-engineering mini-procurement --no-pager
```

`BASE_PATH` を設定しているので、EC2 上でもパスは `/engineering/...` になる:

```bash
curl -s localhost:3101/engineering/healthz   # ok
curl -s localhost:3102/procurement/healthz   # ok
# healthz は DB に繋がないので、DB 接続まで確かめるには API を叩く
curl -s localhost:3101/engineering/api/materials; echo   # MAT-001/002 の JSON が返れば OK
```

> アプリは起動時に DB へ接続しないので、env のパスワードが間違っていても `systemctl status` は
> `active (running)` になる。API を叩いて初めて `password authentication failed` が分かる。

> 既存の `epc-*` Docker コンテナには一切触らない。ポートも 3101/3102 なので 8080 と衝突しない。
> ログは `journalctl -u mini-engineering -f` で見る。

## Step 8. ALB + S3 Sink 用 IAM Role（terraform-alb-s3）

> **費用**: ALB は**起動している間ずっと時間課金**される（ap-northeast-1 で概ね $0.0243/時間
> = 約 $0.58/日、約 $17.5/月 + LCU 課金。**正確な額は
> [AWS の料金ページ](https://aws.amazon.com/jp/elasticloadbalancing/pricing/) と
> リポジトリ外にある見積資料 AWS 料金見積資料 で確認すること**）。
> 「数週間で数ドル」程度では収まらないので、**検証しない期間は `terraform destroy` で消す**のが安い。
> state を分けてあるので、destroy しても Aurora の SG ルール（CDC の通り道）は残り、
> CDC のパイプライン自体は動き続ける。

このステップで作る IAM Role は Confluent Provider Integration の trust policy を持つため、
**apply 前に Confluent 側の情報が要る**（IAM は存在しない Principal を拒否するので、
ダミー値で先に apply することはできない）。順序が前後する点に注意（C7 参照）。

### 8-1. Confluent Cloud で Provider Integration (AWS) を開始

Role 名は固定（`terraform-alb-s3/s3.tf`）なので、Role の ARN は apply 前に分かる。
アカウント ID（`aws sts get-caller-identity --query Account --output text`）を入れると:

```
arn:aws:iam::123456789012:role/example-org-confluent-s3-sink-role
```

Confluent Cloud UI → 対象 Environment → **Provider Integrations → Add integration → AWS**。
画面は次の順に出てくる（手順は PC 側。EC2 での作業は無い）:

| 画面 | 選ぶもの / 入れるもの |
|---|---|
| Select role | **New role**（Role はまだ AWS に無く、8-2 の Terraform で作るため） |
| Select Confluent resource | **S3**（既定は DynamoDB なので変える） |
| 権限ポリシーの案内 | AWS コンソールでは作らない。`s3.tf` の `aws_iam_role_policy` で同じものを作る |
| Provider integration name | 任意（例: `mini-cdc-s3-sink`）。Step 9 で S3 Sink を作るときにこの名前を選ぶ |
| IAM Role ARN | 上の ARN |
| trust policy の表示 | `Principal.AWS`（Confluent 側の `...:role/cspi-xxxxx`）と `sts:ExternalId` をメモする |

> Confluent の案内は「AWS コンソールで Role を作る」前提だが、**コンソールでは作らない**
> （Terraform と二重に作ると同名 Role が衝突する）。
> メモしたら**この画面は開いたまま**にして 8-2 に進み、apply 後に戻って完了させる。

> 画面の文言や手順の細部は Confluent 側の更新で変わることがある。「自分の Role ARN を渡す →
> trust policy をもらう → Role に反映 → 完了」という流れは同じ。

### 8-2. terraform apply

```bash
cd terraform-alb-s3
cp terraform.tfvars.example terraform.tfvars
# Step 0-3 で確認した vpc_id / alb_subnet_ids / ec2_instance_id / ec2_security_group_id と
# mini_app_allowed_cidrs（自分のグローバル IP）、s3_sink_bucket_name に加え、
# 8-1 でメモした Principal / ExternalId を
# confluent_provider_integration_role_arn / confluent_provider_integration_external_id に埋める

terraform init
terraform plan
terraform apply

terraform output engineering_url
terraform output procurement_url
terraform output s3_sink_confluent_role_arn
```

> `terraform plan`/`apply` が `iam:CreateRole` や `iam:CreatePolicy` 系で `AccessDenied` になる
> 場合は、`OrgPermissionBoundary` の不備か権限不足。Step 0-5 を参照して管理者に確認する。
>
> `not authorized to perform: iam:TagRole` で失敗した場合は、Role 作成ではなく**タグ付け**の権限が
> 無いのが原因。`main.tf` の `default_tags` が IAM Role にもタグを付けようとするため、IAM の 2 リソースは
> タグ無しのプロバイダ（`provider = aws.untagged`）で作るようにしてある。

> **`plan` が通っても、IAM の作成権限があるかは分からない**（plan はポリシーを読むだけで作成は試さない）。
> apply で IAM だけ失敗しても、ALB 等の他リソースは作られて**課金が始まる**点に注意。

確認:

- [ ] EC2 コンソール → Target Groups → 2 つとも **healthy**
- [ ] `http://<ALB DNS>/engineering/` で設計側の画面が開く
- [ ] `http://<ALB DNS>/procurement/` で調達側の画面が開く
- [ ] `http://<ALB DNS>/` は 404 固定レスポンス（ルーティングが効いている証拠）

> **既存共有 ALB とは別物**。既存 ALB（`example-org-alb`）自体には触らない。
> ブラウザからの 80 番の許可は、新しく作るミニデモ専用 ALB の SG に入れる。
>
> ただし **EC2 の SG（`sg-0123456789abcdef0`、共有）には 2 ルールを追加する**
> （3101 / 3102 を「ミニデモ ALB の SG から」だけ許可）。個別のルールリソースなので既存ルールは
> 変更されず、`terraform destroy` で消えるのもこの 2 つだけ。構築メモ（非公開） の「インバウンドルールを
> 変えたら SSM が繋がらなくなった」件は既存ルールの変更によるもので、追加とは別。

### 8-3. Confluent Cloud で Provider Integration を完了

8-1 の画面に戻って Provider Integration を完了させる（Confluent が AssumeRole を試して検証する）。
`terraform output s3_sink_confluent_role_arn` が 8-1 で入力した ARN と一致していることも確認する。

## Step 9. S3 Sink Connector

Step 8 で Provider Integration が確定済みなので、Access Key の入力は不要。

```bash
cd terraform-alb-s3
terraform output s3_sink_bucket
```

**Connectors → Add connector → Amazon S3 Sink**

| 設定 | 値 |
|---|---|
| Topics | `mini_aws.engineering.materials` だけ（`dlq-lcc-...` は Postgres Sink の DLQ なので選ばない） |
| Kafka credentials | Step 5 と同じ方式（Service account / My account） |
| Authentication method | **IAM Roles** → Step 8 で作った Provider Integration の名前を選ぶ（`Access Keys` は使わない） |
| AWS S3 region | `ap-northeast-1` |
| Store URL | 空欄（AWS 以外の S3 互換ストレージ用の欄） |
| S3 bucket name | `example-mini-cdc-sink`（`terraform output s3_sink_bucket` の値。`"` は付けない） |
| Input Kafka record value format | `AVRO` |
| Output message format | `JSON`（S3 上で中身が読めるので学習向き） |
| Time interval | `HOURLY` |
| Flush size | `1000`（既定。フルマネージド版は下限があり小さくできない） |
| Maximum span of record time (in ms) before scheduled rotation（JSON では `rotate.schedule.interval.ms`） | **`600000`**（10分。既定の `-1` は無効）。より短くできるならそれでもよい |
| Errors tolerance | **`none`**（既定は `all`。Step 6 と同じ理由） |
| Topics directory | `topics`（既定） |

> **S3 に何も出ない、で悩むポイント**: `Flush size` は「何件たまったら 1 ファイル書くか」。
> デモは数件しか流れないので 1000 件に届かず、そのままでは**いつまで待っても S3 に出ない**。
> `rotate.schedule.interval.ms` を設定すると、件数に関係なく**一定時間ごとに**たまった分を書き出す。
> パスの `hour=HH` は UTC（日本時間 −9 時間）。

確認:

```bash
aws s3 ls s3://example-mini-cdc-sink/topics/ --recursive | tail
```

---

## 通し確認（デモシナリオ）

1. `http://<ALB DNS>/engineering/` で MAT-001 の quantity 変更を申請
2. 「承認」を押す → `engineering.materials` が UPDATE される
3. Confluent Cloud → Topics → Messages にイベントが出る
4. `http://<ALB DNS>/procurement/` の受信一覧に `pending` の行が現れる（5 秒ごとに自動更新）
5. 「Accept」を押す → `procurement.materials` に反映される
6. S3 バケットに同じイベントがアーカイブされている

## トラブルシュート

| 症状 | 原因の候補 |
|---|---|
| Source Connector が `Failed`（接続エラー） | Aurora の `PubliclyAccessible=false` / SG に Confluent Egress IP が無い / `confluent_egress_cidrs` が古い（Confluent 側で変わることがある） |
| Source Connector が `Failed`（slot 関連） | `rds.logical_replication=0` / publication 名が違う / 同名 slot を他メンバーが使用中 |
| Sink Connector が `Failed`（column が無い） | `ReplaceField` の rename 設定漏れ、`fields.whitelist` 漏れ |
| Sink Connector が `Failed`（型エラー） | `updated_at` が `fields.whitelist` に入ってしまっている |
| Sink Connector が `Failed`（NOT NULL 違反） | `auto.evolve=true` で余計な列が追加された。false にして、追加された列を `ALTER TABLE ... DROP COLUMN` で戻す |
| Target Group が `unhealthy` | ヘルスチェックパスが `/engineering/healthz` になっていない / EC2 SG に ALB SG からの 3101/3102 が無い / systemd が落ちている（`journalctl -u mini-engineering -n 50`） |
| ALB で 404 | パスが `/engineering/`（prefix 付き）になっていない。ALB はパスを書き換えないので prefix 必須 |
| S3 に何も出ない | `Flush size` が既定の 1000 のまま |
| アプリが起動しない | `DATABASE_URL` 未設定、または Aurora SG に接続元 IP が無い |

### replication slot の監視（共有 Aurora なので重要）

コネクタを止めた/失敗したまま放置すると、slot が WAL を保持し続けて
**Aurora のストレージを食い潰す**。

```sql
SELECT slot_name, active, restart_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots;
```

`retained_wal` が増え続けていたらコネクタが止まっている。使わないなら下記の後片付けで slot を消す。

---

## 後片付け

**順番が重要**（slot を消す前にコネクタを削除する）。

1. **Confluent Cloud のコネクタを削除**（一時停止だけでは slot が残る）
   - Postgres CDC Source / Postgres Sink / S3 Sink の 3 つ
2. **replication slot と publication を削除**

   ```sql
   SELECT pg_drop_replication_slot('mini_aws_engineering_slot');
   DROP PUBLICATION mini_aws_engineering_pub;
   ```

   > `active = true` のままだと削除できない。コネクタ削除後に実行する。

3. **EC2 の systemd サービス停止**

   ```bash
   sudo systemctl disable --now mini-engineering mini-procurement
   ```

4. **ALB / S3 / IAM Role を削除**

   ```bash
   cd terraform-alb-s3
   terraform destroy
   ```

   > バケットは `force_destroy = true` にしているので、中にオブジェクトが残っていても
   > （バージョニング有効で旧バージョンがあっても）`destroy` でまとめて削除される。

5. **Aurora の SG ルールを削除**

   ```bash
   cd terraform
   terraform destroy
   ```

6. **テーブルを消す場合**（任意）

   ```sql
   DROP TABLE procurement.incoming_material_changes, procurement.materials,
              engineering.material_change_requests, engineering.materials;
   ```

7. Confluent Cloud のクラスター自体も、使わないなら削除する（Basic でも時間課金がある）
8. **コネクタ用に発行した認証情報を削除**。Environment やクラスターを消しても残ることがある。
   - My account を選んだ場合: Administration → API keys で、コネクタ作成時に発行されたキーを削除
   - Service account を選んだ場合: Administration → Accounts & access → Service accounts で削除
     （組織に属するため Environment を消しても残る）。紐づく API キーも消えたか確認する

※Aurora 本体・EC2・既存 ALB はチーム共有リソース
