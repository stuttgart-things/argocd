# apps/openbao/install

App-of-apps chart for OpenBao. Values, seal / topology / self-init modes, the seal Secret and deployment examples
are documented in [`../README.md`](../README.md). Every knob is in [`values.yaml`](values.yaml), and the strict
[`values.schema.json`](values.schema.json) rejects the combinations that would start an instance nobody can
unseal.
