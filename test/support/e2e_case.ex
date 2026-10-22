defmodule AlnaslWeb.E2ECase do
  @moduledoc """
  The browser tests (test/e2e): PhoenixTest's pipeline API, driving a real
  Chromium through Playwright against a real listener, with the database in
  the SQL Sandbox exactly as in any other test.

  Tagged `:e2e` and excluded from a plain `mix test`; `mix test.e2e` runs
  them and nothing else. See docs/e2e.md.

  Never `async: true`: the sandbox is shared with every process the browser
  wakes - the LiveViews, the controllers - and shared mode only works when
  nothing else is running beside it.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use PhoenixTest.Playwright.Case, async: false

      use AlnaslWeb, :verified_routes

      @moduletag :e2e
    end
  end

  setup_all do
    if Application.get_env(:phoenix_test, :base_url) do
      :ok
    else
      raise """
      The browser tests need a listening endpoint and Playwright, which only
      `mix test.e2e` starts (it sets E2E=1 for test/test_helper.exs). See docs/e2e.md.
      """
    end
  end
end
