# Cloud & DevOps Challenge — Kubernetes on AWS

A three-node Kubernetes cluster on AWS, built by one `terraform apply`, serving a
"Hello World" web page over HTTPS. The page is load-balanced across pods on
multiple machines, scales itself up when CPU load rises, and is deployed by a
GitHub Actions pipeline that holds no AWS credentials. Everything is code: there
is no click-ops step anywhere, and `terraform destroy` removes all of it.

---

## Architecture

```
   your browser                        GitHub Actions
        |                                    |
        | HTTPS :443                         | OIDC - short-lived token,
        |                                    | no stored AWS keys
        v                                    v
  +-----------------------------+      +-------------+
  |     Elastic IP (any node)   |      |   AWS  SSM  |
  +-----------------------------+      +-------------+
        |                                    |
        |                                    | send-command
   =====|====================================|============ AWS VPC 10.0.0.0/16
        |                                    |
        v                                    v
  +----------------+     +----------------+     +----------------+
  |  k3s server    |     |  k3s agent 1   |     |  k3s agent 2   |
  |  t3.small      |<--->|  t3.small      |<--->|  t3.small      |
  |                |     |                |     |                |
  |  [ Traefik ]   |     |  [ Traefik ]   |     |  [ Traefik ]   |
  |  [ hello pod ] |     |  [ hello pod ] |     |  [ hello pod ] |
  +----------------+     +----------------+     +----------------+
         ^
         | kubectl :6443 (your IP only)
```

Traefik runs on every node via the ServiceLB built into k3s, so the site answers
on all three public IPs. TLS terminates at Traefik. If a node dies, the other two
keep serving and Kubernetes reschedules its pods.

---

## How this maps to the challenge

| # | Task | Where it lives |
|---|---|---|
| 1 | K8s cluster via IaC, local `kubectl`, 2+ nodes Ready | [terraform/](terraform/), `scripts/get-kubeconfig.sh` |
| 2 | Hello-World container in a browser | [k8s/01-configmap.yaml](k8s/01-configmap.yaml), [k8s/02-deployment.yaml](k8s/02-deployment.yaml) |
| 3 | Multi-node, round-robin, CPU autoscaling | `topologySpreadConstraints` + [k8s/04-hpa.yaml](k8s/04-hpa.yaml) |
| 4 | Ingress controller terminating TLS | Traefik + [k8s/05-ingress.yaml](k8s/05-ingress.yaml); cert from [terraform/tls.tf](terraform/tls.tf) |
| 5 | Bonus I - network hardening, automated and persistent | [k8s/06-hardening.yaml](k8s/06-hardening.yaml) |
| 6 | Bonus II - monitoring concept | [Monitoring concept](#monitoring-concept-bonus-ii), below |
| 7 | Bonus III - CI/CD | [.github/workflows/](.github/workflows/) |

---

## Running it

**Prerequisites:** Terraform 1.5+, AWS CLI configured, `kubectl`, an SSH client.
On Windows use Git Bash for the shell scripts. `scripts/deploy.sh` also needs
`jq`, which is already present on the GitHub runners.

An AWS account can hold only one OIDC provider per issuer URL, so check whether
this one already has the GitHub provider before the first apply:

```bash
aws iam list-open-id-connect-providers
```

If `token.actions.githubusercontent.com` is already listed, set
`create_github_oidc_provider = false` and Terraform will reference the existing
provider instead of failing on `EntityAlreadyExists`.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# set admin_cidr to your IP:  curl -s https://checkip.amazonaws.com
# set github_repo to owner/repo

terraform init
terraform apply
```

Roughly four minutes. Then:

```bash
cd ..
./scripts/get-kubeconfig.sh
export KUBECONFIG=$PWD/kubeconfig

kubectl get nodes        # three Ready nodes
```

Wire up the pipeline once, using two values from `terraform output`:

| GitHub setting | Value |
|---|---|
| Secret `AWS_DEPLOY_ROLE_ARN` | `terraform output github_deploy_role_arn` |
| Variable `SERVER_INSTANCE_ID` | `terraform output server_instance_id` |

Then push to `main`, or run the same deploy locally:

```bash
SERVER_INSTANCE_ID=$(terraform -chdir=terraform output -raw server_instance_id) ./scripts/deploy.sh
```

Open `terraform output app_url`. The certificate is self-signed, so click through
the browser warning - that is expected, and is what the brief permits.

**Teardown:** `terraform destroy`. Nothing is left behind: no state outside the
VPC, no buckets, no log groups, no snapshots.

---

## Demos worth showing

```bash
# Round-robin across pods and nodes. The page also shows this by itself -
# it refreshes every 3 seconds and the pod name changes.
for i in $(seq 6); do curl -sk https://$HOST | grep -o 'hello-[a-z0-9-]*'; done

# Self-healing. Delete a pod and watch it come back with no downtime.
kubectl delete pod -l app=hello --wait=false
kubectl get pods -l app=hello -w

# CPU autoscaling. Generate load, watch replicas climb from 2 toward 6.
kubectl run load --rm -it --image=busybox --restart=Never -- \
  /bin/sh -c 'while true; do wget -q -O- http://hello >/dev/null; done'
kubectl get hpa hello -w

# Pods really are on different machines.
kubectl get pods -l app=hello -o wide
```

---

## Cost

The brief says not to spend money on infrastructure. This is not free - EC2
outside the free tier never is - but it is held as close to the floor as the
requirements allow.

| Item | Per day |
|---|---|
| 3 x t3.small (eu-central-1, on-demand) | $1.64 |
| 3 x Elastic IP | $0.36 |
| 3 x 8 GB gp3 | $0.08 |
| **Total while running** | **~$2.08** |
| Instances stopped (IPs and disks only) | ~$0.44 |

Roughly **6 EUR for a three-day exercise**, less if you stop the instances
between sessions.

What keeps it there:

- **k3s, not EKS.** An EKS control plane is $0.10/hour - $2.40/day on its own,
  more than this entire cluster.
- **No NAT gateway.** One public subnet, no private subnets. A NAT gateway alone
  is ~$32/month, more than the compute.
- **No ALB or NLB.** The ingress controller the challenge asks for already does
  that job. A load balancer in front would be ~$16/month to duplicate it.
- **No container registry and no image build.** The app is stock nginx plus a
  ConfigMap, so there is nothing to build, push or store.
- **`nip.io` and a self-signed certificate.** No domain, no ACM, no money.
- **T3 `standard` credit mode.** The default `unlimited` bills for sustained
  burst. Standard cannot exceed the baseline price, so load-testing the HPA
  cannot produce a surprise on the bill.
- **Elastic IPs.** Same hourly rate as an auto-assigned public IPv4, but they
  survive a stop - so the instances can be shut down overnight and come back to
  the same URL and the same valid certificate.

---

## Decisions

### k3s rather than EKS or kubeadm

**Chose:** k3s, one server and two agents, installed from `user_data`.

**Rejected:** EKS - $73/month for a control plane this brief does not need, and
whose useful features (IRSA, managed node groups) this exercise does not use.
kubeadm - a two-phase bootstrap where the join token only exists after the first
node is up, meaning either a second Terraform run or a fragile provisioner. k3s
takes the token as an *input*, so all three nodes get identical treatment and the
cluster is one `apply`.

k3s is a CNCF-certified Kubernetes distribution. The API and the manifests in
this repo are ordinary Kubernetes; nothing here would need rewriting to move to
EKS.

**What would change my answer:** anything long-lived. The moment this cluster
outlives a demo, a single control-plane node is the wrong trade and $73/month is
cheap next to being paged about etcd.

### Traefik rather than an installed ingress controller

**Chose:** the Traefik that k3s bundles and enables by default.

**Rejected:** ingress-nginx via Helm. It is the more common choice and I would
reach for it in production, but here it means adding Helm to the pipeline and a
component to the explanation, to arrive at the same behaviour. Also rejected: an
AWS ALB in front. It costs money, and it moves TLS termination *off* the ingress
controller - which is exactly what task 4 asks the ingress controller to do.

**What would change my answer:** needing something Traefik does poorly, or an
existing ingress-nginx annotation set to migrate. Swapping is `--disable=traefik`
in [the server bootstrap](terraform/user-data/server.sh.tftpl) plus a Helm install.

### SSM rather than a kubeconfig in GitHub secrets

**Chose:** GitHub Actions federates into AWS via OIDC, then runs `ssm
send-command` against the server node.

**Rejected:** storing a kubeconfig as a GitHub secret and running `kubectl` from
the runner. That needs port 6443 open to GitHub's address ranges - which are wide
and change - and it puts a credential with full cluster admin into a third-party
system, where it does not expire and rotating it is manual.

The chosen path opens no inbound port for CI at all, stores no long-lived
credential anywhere, and makes every deploy a CloudTrail event with an identity
attached. The deploy role can call exactly one API against exactly one instance.

**What would change my answer:** more than a handful of clusters. `send-command`
does not scale as a deployment mechanism; past that point the answer is a
pull-based agent inside the cluster, not a bigger push.

### Applying Terraform by hand, deploying by pipeline

**Chose:** `terraform apply` is run by a human. CI runs `fmt`, `validate` and
schema-lints the manifests, and owns the application rollout.

**Rejected:** `terraform apply` from CI. It needs remote state (an S3 bucket and
a lock table, themselves needing bootstrapping) and a role that can create and
destroy VPCs and IAM roles - a large blast radius for a cluster that gets built
about twice.

This is the one place I have knowingly stopped short of bonus III's wording,
which asks for tasks 1-5 in the pipeline. Tasks 2-5 are fully pipelined. Task 1
is fully automated and reproducible, but deliberately triggered. Closing the gap
is about fifteen lines: an S3 backend block, a `workflow_dispatch` job and a
second OIDC role. I think a human trigger is right for infrastructure with this
lifecycle, and I would rather argue that than hide it.

**What would change my answer:** more than one environment, or more than one
person applying. Shared state and a pipeline become mandatory the moment two
people can both run `apply`.

### Single availability zone

**Chose:** one public subnet in one AZ.

**Rejected:** two or three AZs. It would look more production-shaped, but the
brief sets no availability target, and cross-AZ traffic between Kubernetes nodes
is billed in both directions.

**What would change my answer:** any availability requirement at all. Multi-AZ is
a three-line change here - a second subnet, and spreading the instances across
`data.aws_availability_zones` - which is precisely why it is safe to leave out
now.

---

## Hardening (Bonus I)

Every control below is a Kubernetes object applied by the pipeline, so it
survives a pod restart, a node loss and a full cluster rebuild. Nothing was
configured by hand on a box - which is what makes it *persistent* rather than
merely *present*.

| Control | Standard | Where |
|---|---|---|
| TLS 1.2 minimum, ECDHE and AEAD ciphers only | Mozilla Intermediate | `TLSOption/hardened` |
| HSTS, CSP, frame-deny, nosniff, referrer and permissions policy | OWASP Secure Headers | `Middleware/security-headers` |
| Server version banner stripped | OWASP Secure Headers | `Middleware/security-headers` |
| Plaintext HTTP permanently redirected to HTTPS | - | `Middleware/redirect-https` |
| Per-source-IP rate limiting | - | `Middleware/rate-limit` |
| Pod-level default-deny ingress | CIS Kubernetes 5.3.2 | `NetworkPolicy/hello-allow-ingress-only` |
| Non-root, no capabilities, no privilege escalation, seccomp | CIS Kubernetes 5.2 | `securityContext` in the Deployment |
| Kubernetes API reachable from one IP only | - | `aws_security_group.node` |
| IMDSv2 required | AWS Foundational Security | `metadata_options` |
| Encrypted root volumes | AWS Foundational Security | `root_block_device` |

Verify from outside the cluster:

```bash
HOST=$(terraform -chdir=terraform output -raw ingress_host)
nmap --script ssl-enum-ciphers -p 443 $HOST   # TLS profile
curl -kI https://$HOST                        # response headers
curl -sI http://$HOST | head -1               # 301 to HTTPS
```

---

## Monitoring concept (Bonus II)

Not built. The task asks for the concept, and an unused Prometheus stack would
spend real memory on t3.small nodes to demonstrate nothing.

**What I would measure.** Availability is a user-facing property, so the primary
signal is a black-box probe: request `https://<host>/` from outside the VPC every
30 seconds and record status code and latency. That single number is the one a
non-technical stakeholder can be shown, and the one an SLO should be written
against. Everything else exists to explain a dip in it.

**The layers underneath, in the order I would consult them:**

1. **Black-box / synthetic** - Prometheus Blackbox Exporter, or a CloudWatch
   Synthetics canary. Answers *is the site up?*
2. **Ingress metrics** - Traefik already exposes request rate, error rate and
   latency histograms per router. Answers *is it the application or the network?*
3. **Kubernetes state** - kube-state-metrics: pods not Ready, deployments below
   desired count, HPA pinned at max, nodes NotReady. Answers *is the platform
   healthy?*
4. **Node metrics** - node-exporter: CPU, memory, disk, and specifically the T3
   CPU credit balance, which on burstable instances is a genuine availability
   risk rather than a curiosity.

**How it would be wired.** kube-prometheus-stack via Helm, with Grafana for
dashboards and Alertmanager for routing. Alerts on symptoms, not causes: page on
*error rate above 1% for 5 minutes* or *probe failing*, never on *CPU is high* -
high CPU with a healthy site is not an incident, and paging on it teaches people
to ignore pages.

**The gap I would close first.** Metrics living on the cluster they monitor go
down with it. Production ships them off-box - Amazon Managed Prometheus, or any
hosted backend - so the monitoring survives the outage it exists to report.

---

## What I deliberately left out

| Left out | Why | What adding it costs |
|---|---|---|
| HA control plane | One server node is the honest shape of a demo cluster | 2 more servers with embedded etcd; ~$1.10/day |
| Publicly-trusted certificate | Needs a domain; the brief permits self-signed and forbids spending | cert-manager plus a real domain, or ACM behind an ALB |
| Prometheus / Grafana | Bonus II asks for the concept, not the stack (see above) | ~1.5 GB RAM, so a larger instance type |
| Cluster autoscaling | Task 3 asks for *pod* autoscaling; node autoscaling is a different problem | Karpenter, or an ASG plus cluster-autoscaler |
| Staging environment | There is nothing to promote between | A second `terraform apply` with a different `project` |
| Helm | Raw manifests read better, and the one component that needed a chart ships with k3s | - |
| GitOps (Argo CD, Flux) | A pull-based reconciler is the right answer above roughly three clusters, not at one | An in-cluster controller and a second repo |
| Secrets management | The application has no secrets | External Secrets Operator plus AWS Secrets Manager |

---

## Known weaknesses

**The control plane is a single node.** If the server instance dies, the API
server and etcd go with it. The application keeps serving - Traefik and the pods
on the agents are unaffected, and the site stays up - but nothing can be
deployed, rescheduled or scaled until it comes back. This is the first thing I
would fix, and it is deliberate: HA etcd needs three servers, and the brief asks
for simplicity over resilience.

**The kubeconfig on the server is world-readable** (`--write-kubeconfig-mode
0644`). Fine on a single-tenant box reachable from one IP; wrong on anything
shared.

**The TLS private key passes through Terraform state and EC2 user_data.** Both
are readable by anyone with sufficient AWS permissions. Acceptable for a
throwaway self-signed certificate; a real key belongs in cert-manager, generated
in the cluster and never leaving it.

**Terraform state is local.** One laptop, no locking, no backup. Fine for one
operator, and the first thing to change when there are two.

**Rate limiting is per-instance.** Each Traefik pod counts independently, so the
effective limit is roughly three times the configured number.

**No PodDisruptionBudget.** The rollout itself is safe (`maxUnavailable: 0`), but
a node drain could still take both replicas at once.

**The HPA can outrun the cluster.** Six replicas of a 50m-CPU pod fit
comfortably, but nothing here stops a larger `maxReplicas` from exceeding what
three t3.small nodes can schedule.

---

## What I would change for production

1. **EKS**, and stop hand-rolling a control plane. The line is roughly: when
   someone other than me has to be able to fix it at 3am, or when an upgrade has
   to happen without downtime, $73/month stops being a saving.
2. **Multi-AZ** across three availability zones, with managed node groups and a
   PodDisruptionBudget.
3. **Private subnets** for the nodes, leaving the ingress as the only public
   surface.
4. **A real certificate**, via cert-manager and a Route 53 domain, renewed
   automatically.
5. **Remote Terraform state** in S3 with DynamoDB locking, and `apply` behind a
   reviewed pipeline.
6. **The observability stack described above**, hosted off-cluster.
7. **Image scanning and signing** in CI - irrelevant here because the app is an
   unmodified upstream image, and mandatory the moment it is not.
