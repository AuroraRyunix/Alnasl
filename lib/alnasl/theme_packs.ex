defmodule Alnasl.ThemePacks do
  @moduledoc """
  Colour themes that are not part of the program: folders somebody drops in,
  which turn up in the theme picker after the built-in ones. The format is in
  `docs/theme-packs.md`; in short, a pack is

      <id>/theme.json   {"id", "name", "name_nl"?, "author", "version", "dark", "swatch"}
      <id>/theme.css    rules scoped to [data-theme="<id>"]
      <id>/fonts/*.woff2 (optional)

  ## Where packs come from

    * the **bundled** packs, `priv/theme_packs/<id>` inside the program
      (`bundled_dir/0`), which every build carries;
    * `ALNASL_THEMES_DIR` (config `:themes_dir`), when set;
    * otherwise `<data dir>/themes`, next to the database (`Alnasl.Paths`).

  Both are scanned, and a folder in the user's directory with the same name
  as a bundled one replaces it (the bundled pack is not consulted at all
  then, even if the user's is refused). Bundled packs go through the same
  `load/1` and `Scanner` as any other. Nothing here creates the user's
  folder - a box nobody gave a theme has no reason to grow an empty drawer
  for one.

  ## Nobody in particular

  OpenPairings, where this format comes from, can keep a pack for some
  accounts (`"users"` in `theme.json`). The box has no accounts - the theme
  is chosen per device, like everything about the look - so a `users` list
  here is read past, not refused: the same pack folder works in both
  programs, and in this one it is everybody's.

  ## Refusals

  A pack that does not load is refused, not half-loaded: a bad `theme.json`,
  a stylesheet over 200 KB, or CSS that `Alnasl.ThemePacks.Scanner` will not
  pass. The reason is logged once and shown in the picker, where whoever
  installed it will look before they look at a log.

  Results are cached per pack against the files' size and modification time,
  so a page render costs a directory listing and a few `stat`s, and replacing
  a pack takes effect on the next page load without a restart.
  """

  require Logger

  alias Alnasl.ThemePacks.Scanner

  @css_limit 200 * 1024
  @font_limit 1024 * 1024
  @id_format ~r/\A[a-z0-9][a-z0-9-]{0,39}\z/
  @font_file ~r/\A[a-z0-9_-]+\.woff2\z/
  @hex ~r/\A#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})\z/

  # The built-in themes (`AlnaslWeb.Layouts.themes/0`), plus the two words
  # the first light/dark switch stored, which `assets/js/theme.js` still
  # reads as paper and night. A pack under any of these names would be a
  # pack nobody could ever choose.
  @builtin ~w(system paper night board slate contrast light dark)

  @typedoc "An installed, accepted pack."
  @type pack :: %{
          id: String.t(),
          name: String.t(),
          name_nl: String.t() | nil,
          author: String.t(),
          version: String.t(),
          dark: boolean(),
          swatch: [String.t()],
          path: String.t(),
          etag: String.t()
        }

  @doc "The ids no pack may take."
  def builtin_ids, do: @builtin

  @doc "The largest `theme.css` served, in bytes."
  def css_limit, do: @css_limit

  @doc "The largest font file served, in bytes."
  def font_limit, do: @font_limit

  @doc "Whether `file` is a font name the pack controller may serve."
  def font_file?(file), do: is_binary(file) and file =~ @font_file

  @doc """
  The folder packs are read from. See the moduledoc for the order; whether
  it exists is the scan's business.
  """
  @spec dir() :: String.t()
  def dir do
    resolve_dir(
      Application.get_env(:alnasl, :themes_dir),
      Application.fetch_env!(:alnasl, :data_dir)
    )
  end

  @doc false
  # The decision itself, apart from where its inputs live, so it can be
  # tested without touching the application environment.
  def resolve_dir(themes_dir, data_dir) do
    if is_binary(themes_dir) and themes_dir != "",
      do: themes_dir,
      else: Path.join(data_dir, "themes")
  end

  @doc """
  The folder of packs shipped inside the program (`priv/theme_packs`). Config
  `:bundled_themes_dir` points it elsewhere, which only tests do.
  """
  @spec bundled_dir() :: String.t()
  def bundled_dir do
    case Application.get_env(:alnasl, :bundled_themes_dir) do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> Path.join(to_string(:code.priv_dir(:alnasl)), "theme_packs")
    end
  end

  @doc "Every accepted pack, sorted by name."
  @spec list() :: [pack()]
  def list, do: for({:ok, pack} <- scan(), do: pack)

  @doc "The refused packs, as `{folder name, reason}`."
  @spec refused() :: [{String.t(), String.t()}]
  def refused, do: for({:refused, id, reason} <- scan(), do: {id, reason})

  @doc "The ids of every accepted pack."
  def ids, do: Enum.map(list(), & &1.id)

  @doc "The accepted pack `id`, or `nil`."
  @spec get(String.t()) :: pack() | nil
  def get(id) when is_binary(id) do
    if id =~ @id_format, do: Enum.find(list(), &(&1.id == id)), else: nil
  end

  def get(_), do: nil

  @doc """
  The packs as the root layout hands them to `assets/js/theme.js`: data in
  an attribute, never code in a script.
  """
  def bootstrap_json do
    list()
    |> Enum.map(&%{id: &1.id, dark: &1.dark, css: css_url(&1)})
    |> Jason.encode!()
  end

  @doc "Where a pack's stylesheet is served, versioned by its etag."
  def css_url(%{id: id, etag: etag}), do: "/themes/#{id}/theme.css?v=#{etag}"

  @doc "The name to show for `pack` in `locale`."
  def label(%{name_nl: nl}, "nl") when is_binary(nl), do: nl
  def label(%{name: name}, _locale), do: name

  defp scan do
    # Keyed by folder name, the user's last so that it wins.
    folders = Map.merge(folders(bundled_dir()), folders(dir()))

    folders
    |> Enum.sort()
    |> Enum.map(fn {_name, path} -> load_cached(path) end)
    |> Enum.sort_by(fn
      {:ok, pack} -> {0, String.downcase(pack.name)}
      {:refused, id, _} -> {1, id}
    end)
  end

  defp folders(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        for entry <- entries, path = Path.join(dir, entry), File.dir?(path), into: %{} do
          {entry, path}
        end

      {:error, _} ->
        %{}
    end
  end

  defp load_cached(path) do
    key = {__MODULE__, path}
    stamp = stamp(path)

    case :persistent_term.get(key, nil) do
      {^stamp, result} ->
        result

      _ ->
        result = load_folder(path)

        case result do
          {:refused, id, reason} -> Logger.warning("theme pack #{id} refused: #{reason}")
          _ -> :ok
        end

        :persistent_term.put(key, {stamp, result})
        result
    end
  end

  defp stamp(path) do
    for file <- ["theme.json", "theme.css"] do
      case File.stat(Path.join(path, file), time: :posix) do
        {:ok, %{size: size, mtime: mtime}} -> {size, mtime}
        _ -> nil
      end
    end
  end

  defp load_folder(path) do
    folder = Path.basename(path)

    case load(path) do
      {:ok, pack} ->
        if pack.id == folder,
          do: {:ok, pack},
          else:
            {:refused, folder, "theme.json says id #{inspect(pack.id)}, the folder is #{folder}"}

      {:error, reason} ->
        {:refused, folder, reason}
    end
  end

  @doc """
  Reads and checks the pack in `path`: its `theme.json`, and its `theme.css`
  against the size cap and the scanner. Does not care what the folder is
  called - `mix alnasl.theme_check` runs it on a pack before it is installed
  anywhere.
  """
  @spec load(String.t()) :: {:ok, pack()} | {:error, String.t()}
  def load(path) do
    with {:ok, meta} <- read_meta(path),
         {:ok, css} <- read_css(path),
         :ok <- Scanner.scan(css, meta.id) do
      etag =
        :crypto.hash(:sha256, [Jason.encode!(meta), css])
        |> binary_part(0, 8)
        |> Base.encode16(case: :lower)

      {:ok, Map.merge(meta, %{path: path, etag: etag})}
    end
  end

  defp read_meta(path) do
    with {:ok, text} <- read(Path.join(path, "theme.json"), 16 * 1024, "theme.json"),
         {:ok, json} <- decode(text) do
      meta(json)
    end
  end

  defp read_css(path), do: read(Path.join(path, "theme.css"), @css_limit, "theme.css")

  defp read(file, limit, what) do
    case File.stat(file) do
      {:ok, %{type: :regular, size: size}} when size > limit ->
        {:error, "#{what} is over #{div(limit, 1024)} KB"}

      {:ok, %{type: :regular}} ->
        case File.read(file) do
          {:ok, text} -> {:ok, text}
          {:error, reason} -> {:error, "#{what} unreadable: #{reason}"}
        end

      _ ->
        {:error, "no #{what}"}
    end
  end

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, %{} = json} -> {:ok, json}
      _ -> {:error, "theme.json is not a JSON object"}
    end
  end

  # `users` is not looked at: see "Nobody in particular".
  defp meta(json) do
    id = json["id"]
    swatch = json["swatch"]

    cond do
      not (is_binary(id) and id =~ @id_format) ->
        {:error, "id must be lowercase letters, digits and dashes"}

      id in @builtin ->
        {:error, "id #{id} is a built-in theme"}

      not text?(json["name"]) ->
        {:error, "name is missing or longer than 40 characters"}

      json["name_nl"] != nil and not text?(json["name_nl"]) ->
        {:error, "name_nl is longer than 40 characters"}

      not is_boolean(json["dark"]) ->
        {:error, "dark must be true or false"}

      not (is_list(swatch) and length(swatch) in 3..4 and
               Enum.all?(swatch, &(is_binary(&1) and &1 =~ @hex))) ->
        {:error, "swatch must be 3 or 4 hex colours"}

      true ->
        {:ok,
         %{
           id: id,
           name: json["name"],
           name_nl: json["name_nl"],
           author: string(json["author"]),
           version: string(json["version"]),
           dark: json["dark"],
           swatch: Enum.map(swatch, &String.downcase/1)
         }}
    end
  end

  defp text?(value),
    do: is_binary(value) and String.trim(value) != "" and String.length(value) <= 40

  defp string(value) when is_binary(value), do: String.slice(value, 0, 80)
  defp string(_), do: ""
end
