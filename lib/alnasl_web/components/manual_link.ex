defmodule AlnaslWeb.Components.ManualLink do
  @moduledoc """
  The small "?" beside a page's title that opens the manual at the section
  describing that page. The rail's Help link opens the contents; this one goes
  straight to the section, in a new tab, so the page you were asking about is
  still there when you have read the answer. OpenPairings does the same.

  The targets are a closed list (`targets/0`), so a test can check that each
  one still points at a chapter and a heading that exist: a heading renamed in
  `priv/manual/` would otherwise turn these into links to the top of a chapter
  without anyone noticing.
  """
  use Phoenix.Component
  use Gettext, backend: AlnaslWeb.Gettext

  import AlnaslWeb.CoreComponents, only: [icon: 1]

  @targets %{
    round: {"following-games", "the-round-page"},
    game: {"following-games", "a-board"},
    boards: {"boards-and-ports", "the-boards-page"},
    numbering: {"boards-and-ports", "giving-numbers"},
    outbox: {"recording-and-troubleshooting", "the-outbox"},
    pgn: {"recording-and-troubleshooting", "pgn"},
    recordings: {"recording-and-troubleshooting", "recordings"},
    log: {"recording-and-troubleshooting", "the-log"},
    halls: {"accounts-and-halls", "halls"},
    bridges: {"bridges", "joining"},
    setup: {"openpairings-and-openresults", "linking-to-openpairings"},
    lichess: {"openpairings-and-openresults", "lichess"},
    fair_play: {"fair-play", "what-the-numbers-mean"},
    accounts: {"accounts-and-halls", "open-until-the-first-account"},
    wizard: {"getting-started", "setup-wizard"}
  }

  @doc "Every topic, as `topic => {chapter slug, heading id}`."
  def targets, do: @targets

  @doc "The manual address of `topic`."
  def path(topic) do
    {chapter, anchor} = Map.fetch!(@targets, topic)
    "/help/" <> chapter <> "#" <> anchor
  end

  attr :topic, :atom, required: true, values: Map.keys(@targets)

  def manual_link(assigns) do
    assigns = assign(assigns, :path, path(assigns.topic))

    ~H"""
    <a
      href={@path}
      target="_blank"
      rel="noopener"
      id={"manual-link-#{@topic}"}
      class="manual-help-link"
      aria-label={gettext("Open the manual for this page")}
      title={gettext("Open the manual for this page")}
    >
      <.icon name="help" />
    </a>
    """
  end
end
