defmodule Alnasl.FakeReleases do
  @moduledoc """
  GitHub's "latest release" for the tests: the one request
  `Alnasl.Updates.check/1` makes, answered the way GitHub answers it - a
  release with its assets and an ETag, a 304 for a request that carries
  that ETag, a 404 for a repository that has released nothing, a 403 for
  the rate limit, no connection at all.

  It proves that the box reads such an answer correctly and stays quiet
  when there is none. It proves nothing about github.com.

  A plug given to `Req` under its own key (`config :alnasl,
  :updates_req_options`), like the other stand-ins.
  """

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{release: nil, mode: :ok, requests: []} end, name: __MODULE__)
  end

  @doc "Points the update check at this server."
  def install do
    Application.put_env(:alnasl, :updates_req_options, plug: &__MODULE__.call/1)
    :ok
  end

  def uninstall, do: Application.delete_env(:alnasl, :updates_req_options)

  @doc """
  Publishes `version` as the latest release, with the assets a real one
  carries. `opts`: `:draft`, `:prerelease`, `:tag` (default `v<version>`),
  `:sizes` (asset name => bytes, over the defaults).
  """
  def publish(version, opts \\ []) do
    sizes =
      Map.merge(
        %{
          "AlnaslApp-#{version}-full.nupkg" => 43_000_000,
          "Alnasl-Setup.exe" => 44_000_000,
          "alnasl-windows-x86_64-portable.zip" => 52_000_000,
          "alnasl-linux-x86_64.tar.gz" => 31_000_000,
          "alnasl-linux-aarch64.tar.gz" => 30_000_000,
          "alnasl-macos-aarch64.zip" => 29_000_000
        },
        Keyword.get(opts, :sizes, %{})
      )

    tag = Keyword.get(opts, :tag, "v#{version}")

    release = %{
      "tag_name" => tag,
      "html_url" => "https://github.com/AuroraRyunix/Alnasl/releases/tag/#{tag}",
      "draft" => Keyword.get(opts, :draft, false),
      "prerelease" => Keyword.get(opts, :prerelease, false),
      "assets" => Enum.map(sizes, fn {name, size} -> %{"name" => name, "size" => size} end)
    }

    Agent.update(__MODULE__, &%{&1 | release: release})
  end

  @doc "`:ok`, `:down`, `:rate_limited`, `:garbage`."
  def mode(mode), do: Agent.update(__MODULE__, &%{&1 | mode: mode})

  @doc "The requests received, oldest first: the `if-none-match` header of each, or `nil`."
  def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

  def call(conn) do
    %{release: release, mode: mode} = Agent.get(__MODULE__, & &1)
    asked = List.first(Plug.Conn.get_req_header(conn, "if-none-match"))
    Agent.update(__MODULE__, &%{&1 | requests: [asked | &1.requests]})

    etag = release && ~s(W/"#{:erlang.phash2(release)}")

    cond do
      mode == :down ->
        Req.Test.transport_error(conn, :nxdomain)

      mode == :rate_limited ->
        json(conn, 403, %{"message" => "API rate limit exceeded"})

      mode == :garbage ->
        json(conn, 200, %{"unexpected" => true})

      release == nil ->
        json(conn, 404, %{"message" => "Not Found"})

      asked == etag ->
        Plug.Conn.send_resp(conn, 304, "")

      true ->
        conn |> Plug.Conn.put_resp_header("etag", etag) |> json(200, release)
    end
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
