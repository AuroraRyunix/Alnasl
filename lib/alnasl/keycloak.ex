defmodule Alnasl.Keycloak do
  @moduledoc """
  "Sign in with 02cloud": a minimal confidential OIDC client for the
  Keycloak at `auth.zerotwo.cloud`, realm `zerotwo`, client `alnasl`.

  OpenPairings' own (`PairingsEngine.Keycloak`), with Alnasl's names: one
  identity provider, so the three endpoints are derived from the realm's
  issuer by Keycloak's documented scheme instead of being discovered; the
  plain authorization-code flow with `state` against forgery. No PKCE: the
  code is exchanged server to server with the client secret, which is what
  protects a confidential client.

  What comes back proves an address and nothing more: who that address may
  be here is `Alnasl.Accounts.keycloak_sign_in/2`'s question.
  """

  @token_path "/protocol/openid-connect/token"
  @authorize_path "/protocol/openid-connect/auth"
  @userinfo_path "/protocol/openid-connect/userinfo"

  @doc "Is it set up (a client secret given)? The button shows only then."
  def configured? do
    opts = Application.get_env(:alnasl, :keycloak, [])
    is_binary(opts[:client_id]) and is_binary(opts[:client_secret])
  end

  @doc "Where to send the browser, with the `state` the callback must bring back."
  def authorize_url(state, redirect_uri) when is_binary(state) do
    config = config!()

    query =
      URI.encode_query(%{
        client_id: config.client_id,
        redirect_uri: redirect_uri,
        response_type: "code",
        scope: "openid email profile",
        state: state
      })

    config.issuer <> @authorize_path <> "?" <> query
  end

  @doc "The address Keycloak sends the browser back to: the configured one, else `default`."
  def redirect_uri(default), do: config!().redirect_uri || default

  @doc "Exchanges the code for tokens: `{:ok, %{\"access_token\" => ...}}` or `{:error, reason}`."
  def exchange_code(code, redirect_uri) when is_binary(code) do
    config = config!()

    request(:post, config.issuer <> @token_path,
      form: %{
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri,
        client_id: config.client_id,
        client_secret: config.client_secret
      }
    )
  end

  @doc "Who the token is for: `{:ok, %{\"sub\", \"email\", \"email_verified\", ...}}`."
  def fetch_userinfo(access_token) when is_binary(access_token) do
    request(:get, config!().issuer <> @userinfo_path, auth: {:bearer, access_token})
  end

  @doc false
  # Tests answer through a `Req.Test` stub (`:keycloak_req_plug`); nothing
  # in a test reaches the real Keycloak.
  def request(method, url, opts) do
    opts = Keyword.merge(opts, method: method, url: url, retry: false)

    opts =
      case Application.get_env(:alnasl, :keycloak_req_plug) do
        nil -> opts
        name -> Keyword.put_new(opts, :plug, {Req.Test, name})
      end

    case Req.request(opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp config! do
    opts = Application.fetch_env!(:alnasl, :keycloak)

    %{
      issuer: Keyword.fetch!(opts, :issuer),
      client_id: Keyword.fetch!(opts, :client_id),
      client_secret: Keyword.fetch!(opts, :client_secret),
      redirect_uri: opts[:redirect_uri]
    }
  end
end
