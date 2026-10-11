defmodule AlnaslWeb.DestinationWords do
  @moduledoc """
  Sentences about the places games are sent to: a destination's name, why
  one is not sending, and what each step of Lichess's "Test" found.
  """

  use Gettext, backend: AlnaslWeb.Gettext

  alias AlnaslWeb.Words

  def name("openresults"), do: gettext("Results server")
  def name("lichess"), do: gettext("Lichess broadcast")
  def name(other), do: other

  @doc "What a destination is for, in a line."
  def about("openresults"),
    do: gettext("The results site of the tournament: every move, clock and result, one by one.")

  def about("lichess"),
    do: gettext("A broadcast round on Lichess, fed with the PGN of each game as it changes.")

  def about(_other), do: nil

  @doc "The state as `{tone, icon, word}`."
  def state(%{state: :connected}), do: {"ok", "live", gettext("Connected")}
  def state(%{state: :offline}), do: {"warn", "offline", gettext("Offline")}
  def state(%{state: :blocked}), do: {"bad", "out_of_sync", gettext("Refused")}
  def state(%{state: :unconfigured}), do: {nil, "waiting", gettext("Not set up")}
  def state(%{state: :disabled}), do: {nil, "waiting", gettext("Switched off")}
  def state(%{pending: n}) when n > 0, do: {nil, "waiting", gettext("Waiting")}
  def state(_idle), do: {nil, "waiting", gettext("Nothing sent yet")}

  @doc "Why a destination is not sending."
  def error({:lichess, 401, _message}),
    do: gettext("Lichess does not accept the token. Make a new one and put it in Setup.")

  def error({:lichess, 403, _message}),
    do:
      gettext(
        "Lichess refuses: this token may not write to that broadcast. It must belong to the broadcast's owner (or a contributor) and have the study:write permission."
      )

  def error({:lichess, 404, _message}),
    do: gettext("Lichess does not know that round. Check the round id in Setup.")

  def error({:lichess, 400, message}) when is_binary(message),
    do: gettext("Lichess refuses the games: %{message}", message: message)

  def error({:lichess, status, _message}),
    do: gettext("Lichess refuses what the box sends (%{status}).", status: status)

  def error(:rate_limited),
    do: gettext("Asked to slow down. Sending goes on by itself after the pause.")

  def error(other), do: Words.link_error(other)

  # --- the test ----------------------------------------------------------------

  def step_name(:account), do: gettext("Token")
  def step_name(:scope), do: gettext("Permission")
  def step_name(:round), do: gettext("Round")

  @doc "One step of Lichess's test as `{tone, sentence}`."
  def test_step(:account, {:ok, nil}), do: {"ok", gettext("Lichess accepts the token.")}

  def test_step(:account, {:ok, name}),
    do: {"ok", gettext("Lichess accepts the token: it belongs to %{name}.", name: name)}

  def test_step(:account, {:error, :no_token}),
    do: {"bad", gettext("There is no token. Make one on Lichess and paste it here.")}

  def test_step(:account, {:error, :token_refused}),
    do:
      {"bad",
       gettext(
         "Lichess does not know this token. Was it copied whole? A token is shown once, when it is made."
       )}

  def test_step(:scope, {:ok, _scopes}),
    do: {"ok", gettext("The token may write studies (study:write), which a broadcast needs.")}

  def test_step(:scope, {:error, {:scope_missing, scopes}}),
    do:
      {"bad",
       gettext(
         "The token lacks the study:write permission (it has: %{scopes}). Make a new token with \"Create, update, delete studies and broadcasts\" ticked.",
         scopes: if(scopes == "", do: "-", else: scopes)
       )}

  def test_step(:scope, :unknown),
    do:
      {nil,
       gettext(
         "The token's permissions could not be read. If sending is refused later, make a token with study:write."
       )}

  def test_step(:round, {:ok, %{round: round, tour: tour}}) when is_binary(round),
    do:
      {"ok",
       gettext("The round is there: \"%{round}\" of \"%{tour}\".",
         round: round,
         tour: tour || "?"
       )}

  def test_step(:round, {:ok, _detail}), do: {"ok", gettext("The round is there.")}

  def test_step(:round, {:error, :no_round}),
    do: {"bad", gettext("There is no round id. Paste the link to the round on Lichess.")}

  def test_step(:round, {:error, :round_not_found}),
    do:
      {"bad",
       gettext(
         "Lichess has no round with that id. Paste the link to the round itself, not to the tournament."
       )}

  def test_step(:round, {:error, :round_refused}),
    do: {"bad", gettext("Lichess will not show that round to this token.")}

  def test_step(:round, :unknown),
    do: {nil, gettext("Lichess answered about the round in a way the box does not understand.")}

  def test_step(_step, {:error, :rate_limited}),
    do: {"warn", gettext("Lichess asks to slow down. Wait a minute and test again.")}

  def test_step(_step, {:error, {:unreachable, reason}}),
    do: {"bad", Words.link_error({:unreachable, reason})}

  def test_step(_step, {:error, {:http, status}}),
    do: {"bad", gettext("Lichess answers with an error of its own (%{status}).", status: status)}

  def test_step(_step, :skipped), do: {nil, gettext("Not tested: the step before it failed.")}
  def test_step(_step, _other), do: {"bad", gettext("This step failed.")}
end
