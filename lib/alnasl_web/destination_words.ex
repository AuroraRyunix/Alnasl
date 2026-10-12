defmodule AlnaslWeb.DestinationWords do
  @moduledoc """
  Sentences about the places games are sent to: a destination's name, why
  one is not sending, and what each step of Lichess's "Test" found.
  """

  use Gettext, backend: AlnaslWeb.Gettext

  alias AlnaslWeb.Words

  def name("openresults"), do: gettext("Results server")
  def name("lichess"), do: gettext("Lichess broadcast")
  def name("openpairings"), do: gettext("OpenPairings")
  def name(other), do: other

  @doc "What a destination is for, in a line."
  def about("openresults"),
    do: gettext("The results site of the tournament: every move, clock and result, one by one.")

  def about("lichess"),
    do: gettext("A broadcast round on Lichess, fed with the PGN of each game as it changes.")

  def about("openpairings"),
    do:
      gettext(
        "The pairing program: each game goes back to the tournament it came from, with the result the board saw. Shown beside the pairings there; never entered as the result."
      )

  def about(_other), do: nil

  @doc "The state as `{tone, icon, word}`."
  def state(%{state: :connected}), do: {"ok", "live", gettext("Connected")}
  def state(%{state: :offline}), do: {"warn", "offline", gettext("Offline")}
  def state(%{state: :blocked}), do: {"bad", "out_of_sync", gettext("Refused")}
  def state(%{state: :unconfigured}), do: {nil, "waiting", gettext("Not set up")}
  def state(%{state: :disabled}), do: {nil, "waiting", gettext("Switched off")}
  def state(%{pending: n}) when n > 0, do: {nil, "waiting", gettext("Waiting")}
  def state(_idle), do: {nil, "waiting", gettext("Nothing sent yet")}

  @doc "Why \"Send now\" would do nothing (`Alnasl.Destination.send_plan/1`), in a sentence."
  def quiet(:switched_off), do: gettext("Switched off: switch it on first.")
  def quiet(:nothing_waiting), do: gettext("Nothing is waiting.")

  def quiet(:no_code),
    do: gettext("No connect code: add one under Setup, Tournaments.")

  def quiet(:board_outside),
    do:
      gettext(
        "Nothing is waiting, and a board is not playing in a linked tournament, so what it reads is not reported. Put it in the tournament (the line under the bar)."
      )

  def quiet({:no_key, titles}),
    do:
      gettext(
        "OpenPairings has no relay key for %{names} yet, so there is nowhere to send. In OpenPairings: Settings > Live boards > The results site. Sending starts by itself once the key is there.",
        names: Enum.join(titles, ", ")
      )

  def quiet({:not_set_up, "lichess"}),
    do:
      gettext("Stays off until a round and a token are filled in under Setup, Lichess broadcast.")

  def quiet({:not_set_up, _id}),
    do:
      gettext(
        "No results page yet: a tournament from OpenPairings brings its own; for the box's own tournament give one under Setup."
      )

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

  def error(:unauthorized),
    do:
      gettext(
        "OpenPairings does not accept the connect code: it is wrong, or it was withdrawn there. Make a new code in OpenPairings (Settings, Live boards) and add it in Setup."
      )

  def error(:not_the_api),
    do: gettext("That address answers, but not as OpenPairings' board link.")

  def error({:tournament, name, reason}) when is_binary(name),
    do: name <> ": " <> error(reason)

  def error({:tournament, _unnamed, reason}), do: error(reason)

  def error(other), do: Words.link_error(other)

  @doc "What the pairing program said about one game it did not take."
  def report_error("stale"),
    do:
      gettext(
        "OpenPairings holds a newer report of this game - from another box, or from this one before it was set up again."
      )

  def report_error("pairing_changed" <> _detail),
    do: gettext("the pairing is no longer between these two players, or the colours changed.")

  def report_error("pairing_gone" <> _detail),
    do: gettext("the pairing is not there any more: the round was paired again.")

  def report_error("not_a_game" <> _detail),
    do: gettext("that pairing is a bye or an empty board.")

  def report_error(other), do: other

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
