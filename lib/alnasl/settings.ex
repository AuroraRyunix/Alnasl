defmodule Alnasl.Settings do
  @moduledoc """
  What the arbiter set up for the box as a whole, kept in the database so it
  survives the plug being pulled: the language, the box's name, the PIN, and
  the tracker's timings.

  What belongs to a tournament - its results page and relay key, its Lichess
  round, the round in play - is the tournament's (`Alnasl.Tournaments`): a
  box serves more than one.

  The PIN is stored as a salted hash.
  """

  import Ecto.Query

  alias Alnasl.Repo
  alias Alnasl.Settings.Setting

  @defaults %{
    "box_name" => "Alnasl",
    "locale" => "en",
    "pin" => nil,
    "auto_suggest" => false,
    "new_game_on_setup" => "unpaired",
    "clock_heartbeat_s" => 20,
    "capture_cap_mb" => 500,
    "tracker" => %{}
  }

  @topic "settings"

  def subscribe, do: Phoenix.PubSub.subscribe(Alnasl.PubSub, @topic)

  @doc "A setting, or its default."
  def get(key) when is_binary(key) do
    case Repo.get(Setting, key) do
      nil -> Map.get(@defaults, key)
      %Setting{value: json} -> Jason.decode!(json)
    end
  end

  @doc "Several settings in one query, as a map."
  def get_many(keys) do
    stored =
      Setting
      |> where([s], s.key in ^keys)
      |> Repo.all()
      |> Map.new(&{&1.key, Jason.decode!(&1.value)})

    Map.new(keys, &{&1, Map.get(stored, &1, Map.get(@defaults, &1))})
  end

  def put(key, value) when is_binary(key) do
    Repo.insert!(%Setting{key: key, value: Jason.encode!(value)},
      on_conflict: {:replace, [:value]},
      conflict_target: :key
    )

    Phoenix.PubSub.broadcast(Alnasl.PubSub, @topic, {:setting, key})
    :ok
  end

  def put_many(map), do: Enum.each(map, fn {key, value} -> put(to_string(key), value) end)

  # --- reading what was typed -------------------------------------------------

  @doc """
  Reads what an arbiter pastes: a bare slug, or a link to the tournament on
  the results site (`https://host/t/<slug>/...`). `{server_url | nil, slug}`.
  """
  def parse_tournament(text) do
    text = String.trim(text || "")

    case URI.parse(text) do
      %URI{scheme: scheme, host: host, path: path} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        slug =
          case String.split(path || "", "/", trim: true) do
            ["t", slug | _] -> slug
            ["api", "tournaments", slug | _] -> slug
            _other -> ""
          end

        port = if uri.port in [80, 443, nil], do: "", else: ":#{uri.port}"
        {"#{scheme}://#{host}#{port}", slug}

      _not_a_link ->
        {nil, text}
    end
  end

  @doc "The address as it is used: scheme added, trailing slash removed."
  def normalize_url(text) do
    text = String.trim(text || "")

    cond do
      text == "" ->
        ""

      String.starts_with?(text, ["http://", "https://"]) ->
        String.trim_trailing(text, "/")

      String.starts_with?(text, ["localhost", "127.", "192.168.", "10."]) ->
        "http://" <> String.trim_trailing(text, "/")

      true ->
        "https://" <> String.trim_trailing(text, "/")
    end
  end

  # --- the PIN -----------------------------------------------------------------

  def pin_set?, do: get("pin") != nil

  def set_pin(nil), do: put("pin", nil)
  def set_pin(""), do: put("pin", nil)

  def set_pin(pin) when is_binary(pin) do
    salt = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    put("pin", %{"salt" => salt, "hash" => hash(pin, salt)})
  end

  def pin_valid?(pin) when is_binary(pin) do
    case get("pin") do
      %{"salt" => salt, "hash" => stored} -> Plug.Crypto.secure_compare(hash(pin, salt), stored)
      _none -> true
    end
  end

  def pin_valid?(_other), do: false

  defp hash(pin, salt) do
    1..2_000
    |> Enum.reduce(salt <> pin, fn _i, acc -> :crypto.hash(:sha256, acc) end)
    |> Base.encode16(case: :lower)
  end

  # --- the tracker -------------------------------------------------------------

  @doc "The tracker options: its defaults with what the arbiter changed."
  def tracker_opts do
    stored = get("tracker") || %{}

    Enum.reduce(Alnasl.Tracker.defaults(), [], fn {key, default}, acc ->
      case Map.get(stored, Atom.to_string(key)) do
        nil ->
          acc

        value when is_integer(default) and is_integer(value) and value >= 0 ->
          [{key, value} | acc]

        value when is_boolean(default) and is_boolean(value) ->
          [{key, value} | acc]

        value when key == :promotion_default and value in ~w(q r b n) ->
          [{key, String.to_existing_atom(value)} | acc]

        _bad ->
          acc
      end
    end)
  end
end
