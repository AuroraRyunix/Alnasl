defmodule AlnaslWeb.LinkWords do
  @moduledoc """
  Sentences about the link with OpenPairings: why a connect code was not
  taken, how a link stands, and what "Test connection" found. Nothing the
  arbiter reads here is an error code.
  """

  use Gettext, backend: AlnaslWeb.Gettext

  alias Alnasl.OpenPairings.Code
  alias Alnasl.Tournaments.Link

  @doc "Why what was pasted is not a connect code, or was not kept."
  def code_error(:empty), do: gettext("Paste the connect code first.")

  def code_error(:no_secret),
    do:
      gettext(
        "That is not a whole connect code: the part after the # is missing. Copy the whole line OpenPairings shows, from https:// to the end."
      )

  def code_error(:not_an_address),
    do:
      gettext(
        "That is not a connect code: it should begin with the address of OpenPairings (https://... or http://127.0.0.1:...)."
      )

  def code_error(:already), do: gettext("The box has this code already.")

  def code_error(:unauthorized),
    do:
      gettext(
        "OpenPairings does not know this code: it was mistyped, or it has been withdrawn there. Make a new one in OpenPairings (Settings, Live boards)."
      )

  def code_error({:unsupported, api}),
    do:
      gettext(
        "That OpenPairings speaks version %{api} of the board link, which this box does not know. Update the box.",
        api: inspect(api)
      )

  def code_error(other), do: error(other)

  @doc "Why the pairing program could not be asked."
  def error(:unauthorized),
    do:
      gettext(
        "OpenPairings refuses the connect code: it is wrong, or it was withdrawn there. The box has stopped asking. Make a new code in OpenPairings (Settings, Live boards) and add it here."
      )

  def error({:unreachable, reason}),
    do: gettext("OpenPairings cannot be reached: %{why}", why: unreachable(reason))

  def error(:not_the_api),
    do:
      gettext(
        "Something answers at that address, but not as OpenPairings' board link. A login page of the hall's network, or another program on that port?"
      )

  def error({:unsupported, api}), do: code_error({:unsupported, api})

  def error({:rate_limited, _wait}),
    do: gettext("OpenPairings asks to slow down. The box tries again by itself.")

  def error({:http, status}),
    do: gettext("OpenPairings answers with an error of its own (%{status}).", status: status)

  def error(:tournament_not_found),
    do: gettext("The code no longer reaches that tournament.")

  def error({:refused, _status, code, _detail}),
    do: gettext("OpenPairings refuses the request: %{code}.", code: code)

  def error(_other), do: gettext("Asking OpenPairings failed. It is tried again.")

  defp unreachable(:econnrefused),
    do: gettext("nothing answers at that address. Is OpenPairings running?")

  defp unreachable(:nxdomain), do: gettext("that name does not exist. Is the network up?")
  defp unreachable(:timeout), do: gettext("no answer in time.")
  defp unreachable(:closed), do: gettext("the connection was closed.")

  defp unreachable({:tls_alert, _alert}),
    do: gettext("the secure connection failed. https or http?")

  defp unreachable(_other), do: gettext("no connection.")

  @doc "How a link stands, as `{tone, icon, word}`."
  def state(%Link{state: "ok"}), do: {"ok", "live", gettext("Connected")}
  def state(%Link{state: "unauthorized"}), do: {"bad", "out_of_sync", gettext("Code refused")}

  def state(%Link{state: "unsupported"}),
    do: {"bad", "out_of_sync", gettext("Other version")}

  def state(%Link{state: "unreachable"}), do: {"warn", "offline", gettext("No answer")}
  def state(%Link{}), do: {nil, "waiting", gettext("Not asked yet")}

  @doc "What a link is, in a line: where, and for what."
  def about(%Link{} = link) do
    host = Code.host(link.root)

    cond do
      link.kind == "group" and link.group_name not in [nil, ""] ->
        gettext("%{host}: the group \"%{group}\"", host: host, group: link.group_name)

      link.kind == "group" ->
        gettext("%{host}: a group of tournaments", host: host)

      true ->
        gettext("%{host}: one tournament", host: host)
    end
  end

  @doc """
  What a code reaches that the box has through another code
  (`Alnasl.OpenPairings.Duplicates.shared/1`), in a sentence per
  tournament.
  """
  def elsewhere(shared) when is_list(shared) do
    Enum.map_join(shared, " ", fn found ->
      gettext(
        "This code reaches %{tournament}, which this box already has through %{other} (code %{hint}).",
        tournament: found.name || "?",
        other: about(found.through),
        hint: Alnasl.Tournaments.secret_hint(found.through)
      )
    end)
  end

  @doc "The sentence under a link that does not answer: the reason it last gave."
  def why(%Link{state: "unauthorized"}), do: error(:unauthorized)

  def why(%Link{state: "unreachable"} = link) do
    if Code.loopback?(link.root),
      do:
        gettext(
          "No answer. This code is for an OpenPairings on this same computer: is it running?"
        ),
      else:
        gettext(
          "No answer. The boards go on with the pairings the box has; it asks again by itself."
        )
  end

  def why(%Link{state: "unsupported"}),
    do: gettext("That OpenPairings speaks a version of the board link this box does not know.")

  def why(_link), do: nil

  # --- "Test connection" -------------------------------------------------------

  def step_name(:server), do: gettext("Address")
  def step_name(:code), do: gettext("Code")
  def step_name(:tournaments), do: gettext("Tournaments")

  @doc "One step of the test, in words: `{tone, sentence}`."
  def test_step(:server, :ok), do: {"ok", gettext("OpenPairings answers.")}
  def test_step(:server, {:error, reason}), do: {"bad", error(reason)}
  def test_step(:code, :ok), do: {"ok", gettext("The connect code is accepted.")}
  def test_step(:code, {:error, reason}), do: {"bad", code_error(reason)}

  def test_step(:tournaments, {:ok, []}),
    do:
      {"warn",
       gettext(
         "The code reaches no tournament just now: it was deleted or archived, or the group is empty."
       )}

  def test_step(:tournaments, {:ok, found}),
    do: {"ok", gettext("The code reaches %{count} tournament(s).", count: length(found))}

  def test_step(_step, :skipped), do: {nil, gettext("Not tested: the step before it failed.")}
  def test_step(_step, _other), do: {"bad", gettext("This step failed.")}

  @doc "What the test found for one tournament: `{tone, sentence}`."
  def summary(%{error: reason} = found),
    do: {"bad", "#{found[:name] || "?"}: " <> error(reason)}

  def summary(%{} = found) do
    paired =
      case found.current_round do
        nil ->
          gettext("no round paired yet")

        round ->
          gettext("round %{round} is on, %{boards} board(s)", round: round, boards: found.boards)
      end

    {tone, results} =
      case found.openresults do
        :ok ->
          {"ok", gettext("its results page and relay key came with it")}

        :no_key ->
          {"warn",
           gettext(
             "it is on a results site, but no relay key is saved in OpenPairings (Settings, Live boards): nothing is sent to the results site until one is"
           )}

        :not_published ->
          {"warn",
           gettext("it is not published on a results site, so its moves go to OpenPairings only")}
      end

    {tone, "#{found.name || "?"}: #{paired}; #{results}."}
  end
end
