# Browser tests

`test/e2e` holds the tests that need a real browser: the parts of a page that
run in JavaScript and that `Phoenix.LiveViewTest` never executes. Today that
is the guided tour (`tour_test.exs`): the offer, every stop walked from the
first to the last across the pages it lives on, Back, Skip, and starting it
again from the account menu. What the tour *contains* per role is
`test/alnasl_web/live/tour_test.exs`; this is whether a person can walk it.

They use [phoenix_test_playwright](https://hexdocs.pm/phoenix_test_playwright):
PhoenixTest's `visit |> click |> assert_has` pipeline, driving headless
Chromium through Playwright, inside ExUnit and the SQL Sandbox. Tagged `:e2e`,
so a plain `mix test` and `mix precommit` skip them and need no Node.

## Running them

Once per checkout:

```sh
cd e2e
npm ci
npx playwright install chromium-headless-shell   # into Playwright's own cache
```

Then, on Linux or macOS:

```sh
mix test.e2e
PW_TRACE=true mix test.e2e --failed   # a trace per test, in _build/e2e/traces
```

On **Windows** Erlang cannot start Playwright's driver (a `.js` file), so the
browser runs in a Playwright server and the tests connect to it:

```powershell
cd e2e; npx playwright run-server --port 3333 --host 127.0.0.1   # leave it running
$env:PLAYWRIGHT_WS_ENDPOINT = "ws://127.0.0.1:3333/"; mix test.e2e
```

`mix test.e2e` builds the assets, sets `E2E=1` and runs `mix test --only
e2e`; `test/test_helper.exs` then restarts the endpoint with a listener on
port 4013 (`E2E_PORT`) and starts Playwright. CI runs them in the "Browser
tests" job, with the browser cached, and keeps the traces of a failed run as
the `e2e-traces` artifact (`npx playwright show-trace <file>`).

## Writing one

`use AlnaslWeb.E2ECase`. Never `async: true`: the sandbox is shared with the
LiveViews the browser starts, which only works alone. Wait for `body
.phx-connected` before the first click on a LiveView. What the server is told
by a hook (`pushEvent`) lands a moment after the click; poll for it rather
than asserting at once.
