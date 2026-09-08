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
| 5 | Bonus I - network hardening, automated and persistent | [k8s/06-hardening.yaml](k8s/06-hardening.yaml) and [k8s/00-traefik-config.yaml](k8s/00-traefik-config.yaml), asserted by [scripts/verify-hardening.sh](scripts/verify-hardening.sh) |
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
./scripts/get-kubeconfig.sh   # merges a "cgi-k3s" context into ~/.kube/config
kubectl get nodes             # three Ready nodes, no env var needed
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

Set `HOST=$(terraform -chdir=terraform output -raw ingress_host)` first. On
Windows, run these from Git Bash with `MSYS_NO_PATHCONV=1` set, or the shell
rewrites `/bin/sh` in `kubectl run` arguments into a Windows path and the pod
fails to start.

```bash
# Round-robin across pods and nodes. The page also shows this by itself --
# it refreshes every 3 seconds and the pod name changes.
for i in $(seq 8); do curl -sk https://$HOST | grep -o 'hello-[a-z0-9-]*'; done | sort | uniq -c

# Self-healing. Delete a pod and watch it come back with no downtime.
kubectl delete pod -l app=hello --wait=false
kubectl get pods -l app=hello -w

# Pods really are on different machines.
kubectl get pods -l app=hello -o wide
```

### The autoscaling demo, carefully

Load has to originate from `kube-system`. The NetworkPolicy deliberately blocks
everything else, so the obvious `kubectl run` in `default` is refused -- which
is worth showing on purpose, as proof that bonus I actually works:

```bash
# Blocked, by design
kubectl run np --rm -i --restart=Never --image=busybox --command -- \
  sh -c 'wget -q -T 6 -O- http://hello || echo BLOCKED_BY_NETWORKPOLICY'

# Allowed: Traefik's namespace is the one the policy trusts
kubectl -n kube-system run load --rm -i --restart=Never --image=busybox --command -- \
  sh -c 'for i in 1 2 3 4; do (while true; do wget -q -O- http://hello.default >/dev/null 2>&1; done) & done; sleep 90; kill 0'
```

Watch it climb with `kubectl get hpa hello -w`. Scaling from 2 to 6 replicas
takes about 40 seconds.

**Keep the load under about two minutes.** The nodes are t3.small in `standard`
credit mode, so sustained full-CPU load exhausts the CPU credit balance and the
instances throttle to their 20% baseline. SSH then stops responding, though the
site itself keeps serving. Credits refill at 24/hour per node; the throttling
clears within seconds of stopping the load. This is the direct cost of the
credit-mode choice below, and it is why the load generator above self-terminates.

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

The task makes three separate claims - an industry standard, automated, and
persistent - so they are worth arguing separately.

**Standard.** None of the values below are mine. The cipher list is Mozilla's
Intermediate profile, the headers are the OWASP Secure Headers Project's, and
the network policies follow CIS Kubernetes 5.3.2. Citing a published baseline
means a reviewer can check the work against something other than my judgement.

**Automated.** Every control is code. Nothing was configured by hand on a box,
and `scripts/verify-hardening.sh` re-asserts all of it from the public internet
on every deploy - if a control goes missing, the pipeline goes red rather than
the gap waiting to be noticed.

**Persistent.** Three layers, each surviving something different:

| Layer | Delivered by | Survives |
|---|---|---|
| TLS certificate | Terraform, into k3s' manifests directory at boot | exists before the first deploy |
| Controls and chart config | pipeline, as Kubernetes objects in etcd | pod restart, node loss, k3s restart re-applying its own `traefik.yaml` |
| Assertion | `verify-hardening.sh` as a deploy gate | drift, and me |

**Applied to the entrypoint, not to the route.** This is the part worth a
minute in the meeting. The controls used to be requested per-route, by
annotation on the Ingress - which works until someone adds a second Ingress and
forgets four annotations, and then fails *silently*, because the route still
serves traffic, just with TLS 1.0 and no headers. They now sit on the Traefik
entrypoint instead ([k8s/00-traefik-config.yaml](k8s/00-traefik-config.yaml)),
so every route inherits them, including routes nobody has written yet. Look at
[k8s/05-ingress.yaml](k8s/05-ingress.yaml): it carries no security
configuration at all, and is fully hardened.

| Control | Standard | Where |
|---|---|---|
| TLS 1.2 minimum, ECDHE and AEAD ciphers only | Mozilla Intermediate | `TLSOption/default`, in `kube-system` |
| HSTS, CSP, frame-deny, nosniff, referrer and permissions policy | OWASP Secure Headers | `Middleware/security-headers` |
| Server version banner stripped | OWASP Secure Headers | `Middleware/security-headers` |
| Plaintext HTTP permanently redirected to HTTPS | - | `web` entrypoint redirection |
| Per-source-IP rate limiting | - | `Middleware/rate-limit` |
| Bound to the entrypoint, so no route can opt out | - | `HelmChartConfig/traefik` |
| Ingress controller default-deny, inbound and outbound | CIS Kubernetes 5.3.2 | `NetworkPolicy/traefik-restrict` |
| App pods reachable only from the ingress controller | CIS Kubernetes 5.3.2 | `NetworkPolicy/hello-allow-ingress-only` |
| Non-root, no capabilities, no privilege escalation, seccomp | CIS Kubernetes 5.2 | `securityContext` in the Deployment |
| Anonymous version-check telemetry disabled | - | `globalArguments: []` |
| Kubernetes API reachable from one IP only | - | `aws_security_group.node` |
| IMDSv2 required | AWS Foundational Security | `metadata_options` |
| Encrypted root volumes | AWS Foundational Security | `root_block_device` |
| All of the above asserted on every deploy | - | `scripts/verify-hardening.sh` |

**The TLSOption has to be called `default`, and that is not cosmetic.** It was
originally named `hardened` and bound to the entrypoint with
`--entrypoints.websecure.http.tls.options`. Traefik accepts that flag, logs
nothing, and ignores it: the Kubernetes Ingress provider gives every router
built from an Ingress with `router.tls: "true"` an explicit *empty* TLS config,
and an empty config resolves to the TLSOption named `default` - overriding the
entrypoint value rather than inheriting it.

Nothing about that is visible from outside without a cipher scan. TLS 1.0 and
1.1 were still refused, because that is Traefik's own default rather than
anything we configured, so every protocol and header assertion passed while
`TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA` and its 256-bit sibling were being offered
the whole time. The manifests read correctly; the cluster was not doing what
they said. `verify-hardening.sh` is what caught it, which is the entire argument
for having it.

One more trap in the same area: cipher names are Go's, and Traefik 2.11 rejects
the `_SHA256`-suffixed ChaCha20 spellings. A rejected `TLSOption` does not fall
back to defaults - it breaks the handshake outright, so port 443 stops
answering while port 80 keeps redirecting.

Verify from outside the cluster - the same checks CI runs, and the same script:

```bash
HOST=$(terraform -chdir=terraform output -raw ingress_host)
./scripts/verify-hardening.sh "$HOST"

# or by hand, which is what the script automates
nmap --script ssl-enum-ciphers -p 443 $HOST   # TLS profile
curl -kI https://$HOST                        # response headers
curl -sI http://$HOST | head -1               # 301 to HTTPS
```

The checks deliberately run from the runner rather than on a node: a node
reaching its own Elastic IP hairpins out through the internet gateway and back,
and it would test a path no user takes.

**Why the chart override is applied by the pipeline** and not written into the
server's `user_data` alongside the TLS secret: it would be equally persistent
either way, since the object lives in etcd regardless of who applied it, but
`user_data_replace_on_change = true` means every edit replaces the server and,
through `server_private_ip`, both agents. A full cluster rebuild per tweak is
not a trade worth making. The cost is a short window on a brand-new cluster
between k3s starting Traefik and the first deploy hardening it.

**Upgrading a cluster that is already running:** `kubectl apply` does not prune,
so the objects that moved out of the `default` namespace need removing once.

Note the fully qualified resource names. k3s registers the Traefik CRDs under
*both* `traefik.io` and the legacy `traefik.containo.us`, and a bare
`kubectl get middleware` resolves to the legacy group and cheerfully reports
"No resources found" while the objects sit there in the other one. With
`--ignore-not-found` a bare `delete` would report success and remove nothing.

```bash
kubectl -n default delete tlsoptions.traefik.io hardened --ignore-not-found
kubectl -n default delete middlewares.traefik.io \
  security-headers rate-limit redirect-https --ignore-not-found
kubectl -n default delete ingress hello-http --ignore-not-found

# and the TLSOption that was named "hardened" before it had to be "default"
kubectl -n kube-system delete tlsoptions.traefik.io hardened --ignore-not-found

# and to see what is actually there, always qualify:
kubectl -n kube-system get tlsoptions.traefik.io,middlewares.traefik.io
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

**Sustained load throttles the nodes.** t3.small in `standard` credit mode
cannot exceed its 20% CPU baseline once the credit balance is spent. Under a
sustained load test the balance hit ~1.3 and SSH stopped responding, though
Traefik kept serving the site throughout and everything recovered within
seconds of the load stopping. `unlimited` credits would fix it and reintroduce
the surprise-bill risk the brief warns against; a larger instance type would
fix it and cost more. For a demo cluster, a time-boxed load test is the cheaper
answer -- but it is a constraint, not a free lunch.

**The API server and SSH are pinned to one IP.** `admin_cidr` is a /32, and a
domestic connection rotates it. It changed twice during a single afternoon of
building this, each time silently breaking SSH and `kubectl` until
`terraform apply` refreshed the rule. SSM is unaffected, which is why the
deploy path uses it.

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
