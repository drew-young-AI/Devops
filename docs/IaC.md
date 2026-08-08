# IaC and Resource Planning

## Tool baseline

- OpenTofu: primary IaC engine.
- Checkov: IaC security scanning.
- OPA/Conftest: policy-as-code where needed.
- Ansible: optional host configuration, not the primary cloud provisioning tool.
- Packer: defer until VM image factory is needed.

## State decision

- Local encrypted state: first validation option.
- GitHub/GitLab artifact: report and plan storage only, not authoritative state.
- MinIO: optional S3-compatible backend for artifacts, model files, backups and state experiments.
- Cloud backend: future provider adapter.

MinIO is object storage. It does not replace PostgreSQL or another structured database.

## Required evidence

```text
fmt -> validate -> checkov -> plan -> review -> apply
```

Every apply records commit, actor, variables, plan, approval and result.
