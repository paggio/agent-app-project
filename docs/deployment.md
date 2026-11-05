# Deployment architecture

What `dev` runs, as deployed: account `740172916922`, `eu-west-1`. A `prod` would be another
`infra/envs/<env>/` root with the same modules and chart — none exists yet. Owned by `infra/`;
its `docs/architecture.md` is the prose and the reasons, this page is the map.
`check-docs.py [deployment-doc]` fails when a value here disagrees with `infra/`.

## 1. The whole system

```mermaid
flowchart LR
  user([Browser])
  dev([Developer])

  subgraph edge["Edge (global)"]
    cfApp["CloudFront<br/>app distribution"]
    cfPhx["CloudFront<br/>Phoenix distribution"]
  end

  subgraph vpc["VPC 10.42.0.0/16"]
    alb["Internal ALB :80<br/>Host rule → app | Phoenix"]
    subgraph eks["EKS cluster agentapp-dev<br/>Kubernetes 1.36"]
      proxy["proxy ×2<br/>Caddy"]
      fe["frontend ×2"]
      be["backend ×2–4<br/>FastAPI + LangGraph"]
      worker["call-worker ×1"]
      sim["call-simulator ×1"]
      os[("OpenSearch ×1<br/>10Gi gp3")]
      phx["Phoenix ×1"]
    end
    rds[("RDS PostgreSQL 17<br/>db.t4g.micro<br/>chatbot + phoenix DBs")]
    nat["NAT gateway"]
  end

  subgraph aws["Regional AWS services"]
    sqs["SQS agentapp-dev-calls<br/>+ calls-dlq"]
    s3[("S3 documents")]
    bedrock["Bedrock<br/>Claude Haiku 4.5"]
    sm["Secrets Manager"]
    ecr["ECR<br/>backend · frontend · proxy"]
    cw["CloudWatch Logs"]
  end

  user -- HTTPS --> cfApp
  dev -- HTTPS --> cfPhx
  cfApp -- VPC origin --> alb
  cfPhx -- VPC origin --> alb
  alb --> proxy
  alb --> phx
  proxy -- "/api/*" --> be
  proxy -- "everything else" --> fe
  be --> rds
  be --> os
  be -- S3 gateway endpoint --> s3
  be -- via NAT --> bedrock
  sim -- SendMessage --> sqs
  sqs -- long poll --> worker
  worker --> os
  worker --> rds
  be -. OTLP .-> phx
  worker -. OTLP .-> phx
  phx --> rds
  eks -. images .-> ecr
  eks -. synced by External Secrets .-> sm
  eks -. Fluent Bit .-> cw
```

## 2. Network

```mermaid
flowchart TB
  internet((Internet))
  cf["CloudFront<br/>origin-facing prefix list"]

  subgraph vpc["VPC 10.42.0.0/16 — 2 AZs"]
    subgraph azA["eu-west-1a"]
      pubA["public 10.42.128.0/24<br/>NAT gateway (the only one)"]
      privA["private 10.42.0.0/19<br/>2 Spot nodes t3a.large<br/>ALB · RDS · EKS ENIs"]
    end
    subgraph azB["eu-west-1b"]
      pubB["public 10.42.129.0/24"]
      privB["private 10.42.32.0/19<br/>ALB · RDS subnet group · EKS ENIs<br/>(no nodes)"]
    end
    s3ep["S3 gateway endpoint"]
  end

  internet --> cf
  cf -- "VPC origin, ALB is internal" --> privA
  privA -- egress: Bedrock, SQS, ECR, STS --> pubA --> internet
  privA --> s3ep
```

- Nodes are in one AZ on purpose: cheap, and OpenSearch's gp3 volume is zonal.
- One NAT, no interface endpoints: SQS and Bedrock traffic is cents; an endpoint is ~$15/month.
- The ALB admits only CloudFront's origin-facing prefix list; nothing in the VPC is public.

## 3. Inside the cluster

```mermaid
flowchart LR
  alb["Internal ALB<br/>TargetGroupBindings"]

  subgraph ns["namespace agentapp"]
    proxy["Deployment proxy ×2<br/>:8080"]
    fe["Deployment frontend ×2<br/>:8080"]
    be["Deployment backend<br/>HPA 2–4, CPU 70%<br/>:8000"]
    worker["Deployment call-worker ×1<br/>no HTTP — heartbeat probe"]
    sim["Deployment call-simulator ×1<br/>no ingress at all"]
    os[("StatefulSet opensearch ×1<br/>:9200 · PVC 10Gi")]
    phx["Deployment phoenix ×1<br/>:6006 HTTP · :4317 gRPC"]
    jobs["Hook Jobs<br/>phoenix-db · phoenix-admin"]
    sec["Secrets<br/>backend · db-admin · phoenix"]
  end

  subgraph system["other namespaces"]
    eso["external-secrets"]
    lbc["kube-system:<br/>AWS LB controller, CoreDNS,<br/>VPC CNI, EBS CSI, pod identity"]
    cwa["amazon-cloudwatch:<br/>Fluent Bit, CloudWatch agent"]
  end

  alb --> proxy
  alb --> phx
  proxy --> fe
  proxy --> be
  be --> os
  be --> phx
  worker --> os
  worker --> phx
  eso --> sec
```

Every arrow inside `agentapp` is a NetworkPolicy allow rule; the default is deny ingress.
OpenSearch has no auth plugin, so its policy is its only access control.

| Workload | Image | Requests → limits | Identity (pod identity → IAM) |
| --- | --- | --- | --- |
| backend | ECR `agentapp/chatbot-backend` | 250m/768Mi → 1/1536Mi | S3 documents, Bedrock |
| call-worker | same image, `python -m app.calls.worker` | 100m/512Mi → 1/1536Mi | SQS receive/delete, DLQ send, Bedrock |
| call-simulator | same image, `python -m app.calls.simulator` | 25m/128Mi → 250m/512Mi | SQS send to the main queue only |
| frontend | ECR `agentapp/frontend` | 25m/32Mi → 200m/128Mi | — |
| proxy | ECR `agentapp/frontend-proxy` | 50m/64Mi → 500m/256Mi | — |
| opensearch | `opensearchproject/opensearch:2.19.1` | 250m/1Gi → 1/1536Mi | — |
| phoenix | `arizephoenix/phoenix:version-20.4.0` | 100m/512Mi → 1/1Gi | — |

## 4. A chat turn

```mermaid
sequenceDiagram
  autonumber
  participant B as Browser
  participant CF as CloudFront
  participant ALB as Internal ALB
  participant P as proxy
  participant BE as backend
  participant G as LangGraph turn
  participant DB as RDS
  participant OS as OpenSearch
  participant LLM as Bedrock
  participant PX as Phoenix

  B->>CF: POST /api/v1/threads/{id}/messages
  CF->>ALB: VPC origin
  ALB->>P: target group (pod IPs)
  P->>BE: strip /api
  BE->>DB: session, thread history
  BE->>G: coordinate → documents | calls | general
  alt documents
    G->>OS: kb-chunks (this account only)
  else calls
    G->>OS: calls-chunks (organisation-wide)
  end
  G->>LLM: answer (create_agent loop)
  BE->>DB: store message + route + citations
  BE-->>B: 200, X-Trace-Id
  BE--)PX: spans (batch OTLP), tagged conversation, route:‹spoke›
```

## 5. A call, from producer to answer

```mermaid
sequenceDiagram
  autonumber
  participant S as call-simulator
  participant Q as SQS calls
  participant DLQ as SQS calls-dlq
  participant W as call-worker
  participant E as embedder (in-process)
  participant OS as OpenSearch calls-chunks
  participant DB as RDS calls table
  participant PX as Phoenix chatbot-backend-calls

  loop every 60 s
    S->>Q: CallCompleted v1
  end
  W->>Q: ReceiveMessage (long poll)
  alt invalid schema, unmasked phone, past 7 days
    W->>DLQ: send, then delete from Q
  else valid
    W->>E: chunk transcript, embed (bge-small)
    W->>OS: upsert chunks (HNSW)
    W->>DB: upsert call by call_id
    W->>Q: DeleteMessage
  end
  Note over Q: a transient failure is redelivered,<br/>DLQ after 3 receives
  W--)PX: call.ingest span
  loop every hour
    W->>OS: delete calls past retention
    W->>DB: delete calls past retention
  end
```

Queue retention: main 4 days, DLQ 14. Calls are readable for 7 days after `ended_at`.

## 6. Secrets and identity

```mermaid
flowchart LR
  subgraph boot["bootstrap (survives dev-down)"]
    op["agentapp/dev/operator-password"]
  end
  subgraph env["envs/dev"]
    rdsSec["RDS-managed master secret"]
    phxSec["phoenix-secret · phoenix-api-key"]
    signup["signup code"]
  end
  eso["External Secrets"] --> k8s["Kubernetes Secrets"]
  op --> eso
  rdsSec --> eso
  phxSec --> eso
  signup --> eso
  k8s --> be["backend<br/>DATABASE_URL, signup code,<br/>operator seed, Phoenix key"]
  k8s --> phx["phoenix<br/>DB URL, secret, admin password"]
  pi["EKS Pod Identity"] --> be & worker["call-worker"] & sim["call-simulator"]
```

The fixed login: `operator@agentapp.test` (app) and `admin@localhost` (Phoenix) share
`operator-password`. `make -C infra credentials ENV=dev SHOW=1` prints it; every
`/dev-push` comment carries it.

## 7. Observability

```mermaid
flowchart LR
  be["backend"] -- "OTLP HTTP :6006" --> phx["Phoenix"]
  worker["call-worker"] -- "OTLP HTTP :6006" --> phx
  phx --> rds[("RDS phoenix DB")]
  phx --- p1["project chatbot-backend<br/>API + conversations"]
  phx --- p2["project chatbot-backend-calls<br/>call.ingest"]
  phx --- p3["project chatbot-eval<br/>eval runs, datasets, experiments"]
  pods["every pod"] -- "Fluent Bit" --> cw["CloudWatch<br/>/aws/containerinsights/agentapp-dev/application<br/>7 days"]
```

## 8. How it gets deployed

```mermaid
flowchart LR
  pr["control PR comment<br/>/dev-push"] --> gha["GitHub Actions<br/>dev-push.yml (main's copy)"]
  gha --> set["resolve deploy set<br/>slices at feat/‹change›, rest at repos.lock"]
  set --> build["build + push images<br/>→ ECR"]
  build --> tf["terraform apply<br/>envs/dev"]
  tf --> helm["helm upgrade --install --wait<br/>charts/agentapp"]
  helm --> check["deploy checks<br/>images · target health · both logins"]
  check --> smoke["baseline + change smoke<br/>through CloudFront"]
  smoke --> comment["verdict + deployed commits<br/>+ sign-in, on the PR"]
```

The session CI deploys with is the one `make login && make push-gh-creds` hands it; it
assumes the bootstrap deployer role.

## 9. What survives `make dev-down`

| Survives (bootstrap, cents a month) | Destroyed (envs/dev, ~$0.45 an hour) |
| --- | --- |
| Terraform state bucket | VPC, subnets, NAT, S3 endpoint |
| ECR repositories and their images | EKS cluster, nodes, add-ons, OpenSearch volume |
| Deployer role and its policies | RDS — every account, thread and call is lost |
| Budget, cost export, Athena workgroup | SQS queues, documents bucket |
| `operator-password` | ALB, CloudFront distributions and VPC origin |
| | Secrets Manager secrets of the environment |

## 10. Locally

`make up` runs the same services with Docker Compose on one origin, `http://localhost:8080`.
ElasticMQ stands in for SQS, MinIO for S3, and a postgres container for RDS. Phoenix is at
`:6006` with no login. `stack/compose.yml` joins each repo's own compose file.
