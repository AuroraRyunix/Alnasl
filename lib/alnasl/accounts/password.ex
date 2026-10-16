defmodule Alnasl.Accounts.Password do
  @moduledoc """
  Password hashes: PBKDF2-HMAC-SHA512 from OTP's own `:crypto`, a random
  salt per password, stored as `pbkdf2-sha512$<iterations>$<salt>$<hash>`.

  Not a dependency: the usual libraries are either C (bcrypt, argon2), which
  must be compiled on a Raspberry Pi and on Windows from a path with a space
  in it, or a wrapper round the very function used here. OpenPairings uses
  the wrapper; the hashes have the same strength.
  """

  @algorithm "pbkdf2-sha512"
  @salt_bytes 16
  @hash_bytes 64
  # OWASP's figure for PBKDF2-HMAC-SHA512 (2023). Tests ask for far fewer.
  @iterations Application.compile_env(:alnasl, :pbkdf2_iterations, 210_000)

  @doc "The stored form of `password`."
  def hash(password) when is_binary(password) do
    salt = :crypto.strong_rand_bytes(@salt_bytes)
    digest = derive(password, salt, @iterations)

    Enum.join(
      [
        @algorithm,
        @iterations,
        Base.encode64(salt, padding: false),
        Base.encode64(digest, padding: false)
      ],
      "$"
    )
  end

  @doc "Whether `password` is the one `stored` was made from. Constant time in the comparison."
  def verify(password, stored) when is_binary(password) and is_binary(stored) do
    with [@algorithm, iterations, salt, digest] <- String.split(stored, "$"),
         {iterations, ""} <- Integer.parse(iterations),
         {:ok, salt} <- Base.decode64(salt, padding: false),
         {:ok, digest} <- Base.decode64(digest, padding: false) do
      Plug.Crypto.secure_compare(derive(password, salt, iterations), digest)
    else
      _bad -> false
    end
  end

  def verify(_password, _stored), do: no_user_verify()

  @doc "Spends the time a check would, and says no: an unknown address takes as long as a wrong password."
  def no_user_verify do
    derive("", <<0::size(@salt_bytes * 8)>>, @iterations)
    false
  end

  defp derive(password, salt, iterations),
    do: :crypto.pbkdf2_hmac(:sha512, password, salt, iterations, @hash_bytes)
end
