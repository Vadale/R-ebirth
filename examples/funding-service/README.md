# Local funding-extraction service

Application template under approved D-034. One trusted user on `127.0.0.1`, one
persistent model worker, one active extraction and no pending-job queue. The
[contract](../../docs/service-contract.md) defines the operating limits; the
[acceptance runner](../../tests/funding-service/README.md) records what has
actually been tested. This is not a public network deployment or a new relm API.

## Prepare once

Use a trusted installed library containing the exact
[23 application pins](../../tests/service-contract/dependencies.csv), the checked
relm 0.3.0 build and nanoarrow. Prepare a new environment and store for this
release; existing development snapshots and acceptance receipts keep their
original package/source identities. Explicit dependency preparation can use:

```sh
Rscript --vanilla tests/funding-service/install-pins.R /absolute/service-library
```

That command may download/install approved pins. It does not build relm or
install into your personal R library. Supply the validated relm/nanoarrow build
in the same library before setup. On Linux, source installation may need the
usual R development tools plus libsodium, libcurl, zlib and ICU development
libraries. Package versions alone do not identify installed bytes; setup copies
and fingerprints the complete service library.

Use an existing verified model, with either the Spark or Qwen alias from the
registry. No additional model copy is made. The Mac recipe is:

```sh
Rscript --vanilla examples/funding-service/setup.R \
  --source-library /absolute/service-library \
  --model /absolute/Spark-X2.5-4B-Q8_0.gguf \
  --model-alias spark-x2.5-4b-q8_0 --backend metal \
  --environment /absolute/funding/environment
```

For Linux choose the pinned `qwen2.5-0.5b-instruct-q8_0` model and `--backend cpu`.
The prepared environment binds package bytes, R/platform, service source,
contract, native library, model, prompt/schema and sampling. Changing any of
these requires a new environment and a new store. Do not edit a live environment.
No start, request, status, stop or recovery operation installs/downloads anything.

## Start, submit, retrieve, stop

Run in a terminal:

```sh
Rscript --vanilla examples/funding-service/start.R \
  --environment /absolute/funding/environment --store /absolute/funding/store
```

From another terminal:

```sh
curl --fail-with-body http://127.0.0.1:8765/health/ready
curl --fail-with-body -H 'Content-Type: application/json' \
  --data-binary @request.json http://127.0.0.1:8765/v1/extractions
curl --fail-with-body http://127.0.0.1:8765/v1/extractions/my-request
Rscript --vanilla examples/funding-service/status.R \
  --environment /absolute/funding/environment --store /absolute/funding/store
Rscript --vanilla examples/funding-service/stop.R \
  --environment /absolute/funding/environment --store /absolute/funding/store
```

`request.json` contains exactly `id`, `target`, `text`, `seed`, matching one
entry in the [D2 development inputs](../funding-extraction/documents.json).
Use a unique ID, then repeat that same ID/input to retrieve its existing outcome.
A POST 202 is admission, not successful extraction. GET 202 means still running;
GET 200 returns a terminal record whose `state` must be inspected. States include
`success`, `invalid`, `error` and `interrupted`. Domain validation does not prove
factual accuracy. Raw output is retained within limits; oversized output produces
an explicit error with a marked prefix, original length and digest.

A different request while busy gets 429; unavailable/restarting gets 503. Both
include `Retry-After: 1`. A changed payload for an existing ID gets 409. Do not
poll faster than once per second. Readiness is 503 while busy; liveness can still
be 200. Browser origins, chunked/compressed requests and arbitrary model paths,
R code, schemas or prompts are outside the request interface.

## Recovery and privacy

Restart with the same command/environment/store after a frontend crash. Recovery
checks process birth times and ownership before touching old workers or private
IPC directories. Completed records remain immutable; unresolved admissions
become `interrupted`, never automatically rerun. An explicit new request ID is
required for retry. If ownership is uncertain, the service refuses recovery:
inspect the recorded process identity instead of deleting a lock by age or PID.
A corrupt/foreign store or environment also refuses reuse.

Stores contain document text and outputs. Keep them private. At the 10,000-ID or
2 GiB limit, stop the service, retain/export the old store and choose a new one;
there is no automatic result deletion. Temporary worker IPC is private and its
recursive cleanup requires confirmed death. Memory/IPC budgets are monitored
stop thresholds, not OS-enforced allocation ceilings.

## Optional user-level supervision

Generate a definition with a unique service name; generation does not install it:

```sh
Rscript --vanilla examples/funding-service/supervisor.R \
  --manager launchd --name org.relm.funding \
  --environment /absolute/funding/environment --store /absolute/funding/store \
  --output /absolute/org.relm.funding.plist
```

On Mac, explicitly load it with `launchctl bootstrap gui/$(id -u) /absolute/org.relm.funding.plist`.
Use the cooperative `stop.R` command first, then
`launchctl bootout gui/$(id -u)/org.relm.funding` to unload the job.
The LaunchAgent is tied to the logged-in user; no root daemon is installed.

For Linux generate with `--manager systemd-user --name relm-funding` and output
`/absolute/relm-funding.service`, then explicitly run:

```sh
systemctl --user link /absolute/relm-funding.service
systemctl --user daemon-reload
systemctl --user start relm-funding.service
systemctl --user status relm-funding.service
systemctl --user stop relm-funding.service
```

Manager status alone does not establish model readiness; check `/health/ready`.
These definitions use existing restart supervision. Test the actual manager on
the declared host; generating a plist/unit is not lifecycle acceptance. The
service does not promise login-independent operation or enable lingering for you.
