defmodule AlnaslWeb.OpenPairingsConnectController do
  @moduledoc """
  "Connect an OpenPairings account" on Setup, Tournaments
  (`Alnasl.OpenPairings.Connect`): `start/2` sends the browser to
  OpenPairings with a fresh `state` kept in this browser's session,
  `callback/2` takes it back, checks the `state`, trades the grant for a
  code and adds the code to the hall the arbiter was in when they pressed
  the button.

  Behind the gate like every page (the PIN, or signing in), and for an
  owner or arbiter of that hall only - checked on the way out and again on
  the way back, since a role can change in the minute between.

  The way back is `/setup/openpairings/callback` on the address the browser
  used, which behind a proxy is the public one (`x-forwarded-proto`).
  """

  use AlnaslWeb, :controller

  alias Alnasl.{Halls, Log, OpenPairings, Settings}
  alias Alnasl.Accounts.Scope
  alias Alnasl.OpenPairings.{Code, Connect}
  alias AlnaslWeb.LinkWords

  @session :openpairings_connect

  # Long enough to sign in at OpenPairings first, short enough that a
  # forgotten tab does not keep a door open all weekend.
  @max_age_s 15 * 60

  def start(conn, params) do
    hall_id = here(conn)
    typed = get_in(params, ["connect", "address"])

    cond do
      not may?(conn, hall_id) ->
        refuse(
          conn,
          gettext("Your role in this hall lets you follow the games, not change them.")
        )

      true ->
        case Connect.normalize(typed) do
          {:ok, address} ->
            state = Connect.new_state()
            Connect.remember(address)

            conn
            |> put_session(@session, %{
              "state" => state,
              "address" => address,
              "hall_id" => hall_id,
              "at" => System.system_time(:second)
            })
            |> redirect(
              external:
                Connect.connect_url(address, callback_url(conn), state, box_label(hall_id))
            )

          {:error, :not_an_address} ->
            refuse(
              conn,
              gettext(
                "That is not the address of an OpenPairings: it should look like https://pairings.example.org, or http://127.0.0.1:4000 for a copy on this computer."
              )
            )
        end
    end
  end

  def callback(conn, params) do
    pending = get_session(conn, @session)
    conn = delete_session(conn, @session)

    with {:ok, %{"address" => address, "hall_id" => hall_id}} <- check_state(pending, params),
         true <- may?(conn, hall_id) || {:error, :role} do
      finish(conn, address, hall_id, params)
    else
      {:error, :role} ->
        refuse(
          conn,
          gettext("Your role in this hall lets you follow the games, not change them.")
        )

      {:error, :state} ->
        refuse(
          conn,
          gettext(
            "That answer from OpenPairings does not belong to a connection this browser started, or it took longer than a quarter of an hour. Nothing was added. Press \"Connect an OpenPairings account\" again."
          )
        )
    end
  end

  defp finish(conn, _address, _hall_id, %{"error" => "denied"}) do
    refuse(conn, gettext("Cancelled in OpenPairings. Nothing was added."))
  end

  defp finish(conn, _address, _hall_id, %{"error" => "too_many_codes"}) do
    refuse(
      conn,
      gettext(
        "That OpenPairings account already has 8 boxes connected. Withdraw one there (account page, Live boards) and try again."
      )
    )
  end

  defp finish(conn, _address, _hall_id, %{"error" => _other}) do
    refuse(conn, gettext("OpenPairings did not connect the account. Nothing was added."))
  end

  defp finish(conn, address, hall_id, %{"grant" => grant}) when is_binary(grant) do
    case Connect.redeem(address, grant) do
      {:ok, code} ->
        added(conn, OpenPairings.add_code(code, hall_id))

      {:error, :expired} ->
        refuse(
          conn,
          gettext(
            "OpenPairings no longer accepts that answer: it is good once and for two minutes. Press \"Connect an OpenPairings account\" again."
          )
        )

      {:error, reason} ->
        Log.add(:warn, "link.connect_failed", %{
          server: Code.host(address),
          reason: inspect(reason)
        })

        refuse(conn, LinkWords.error(reason))
    end
  end

  defp finish(conn, _address, _hall_id, _params),
    do: refuse(conn, gettext("OpenPairings answered with something incomplete. Try again."))

  defp added(conn, {:ok, link, tournaments}) do
    info(
      conn,
      gettext("Connected: %{about}. %{count} tournament(s) on the box now.",
        about: LinkWords.about(link),
        count: length(tournaments)
      )
    )
  end

  defp added(conn, {:pending, _link, reason}) do
    refuse(
      conn,
      gettext(
        "The account is connected, but OpenPairings could not be asked yet: %{why} The box asks again by itself.",
        why: LinkWords.error(reason)
      )
    )
  end

  defp added(conn, {:error, reason}), do: refuse(conn, LinkWords.code_error(reason))

  defp check_state(%{"state" => expected, "at" => at} = pending, %{"state" => state})
       when is_binary(expected) and is_binary(state) do
    if Plug.Crypto.secure_compare(state, expected) and
         System.system_time(:second) - at <= @max_age_s,
       do: {:ok, pending},
       else: {:error, :state}
  end

  defp check_state(_pending, _params), do: {:error, :state}

  defp here(conn),
    do: Scope.hall_id(conn.assigns[:current_scope]) || Halls.own_id()

  defp may?(conn, hall_id) do
    case conn.assigns[:current_scope] do
      %Scope{} = scope -> Scope.can?(scope, :arbiter, hall_id)
      _none -> false
    end
  end

  # "Alnasl - Hall A": what the OpenPairings page shows, and what the
  # account page there lists the box as.
  defp box_label(hall_id) do
    name =
      case Halls.get(hall_id) do
        %{name: name} when is_binary(name) and name != "" -> name
        _none -> Settings.get("box_name") || "Alnasl"
      end

    String.slice("Alnasl - " <> name, 0, 80)
  end

  defp refuse(conn, text), do: conn |> put_flash(:error, text) |> redirect(to: ~p"/setup")
  defp info(conn, text), do: conn |> put_flash(:info, text) |> redirect(to: ~p"/setup")

  # The address the browser used: behind the tunnel the request arrives in
  # plain HTTP and says so in `x-forwarded-proto`. A forged header changes
  # only where this browser is sent back to, which is this browser's affair.
  defp callback_url(conn) do
    {scheme, port} =
      case get_req_header(conn, "x-forwarded-proto") do
        [proto | _] when proto in ["http", "https"] -> {proto, nil}
        _none -> {to_string(conn.scheme), conn.port}
      end

    port = if port in [nil, 80, 443], do: nil, else: port

    URI.to_string(%URI{
      scheme: scheme,
      host: conn.host,
      port: port,
      path: "/setup/openpairings/callback"
    })
  end
end
