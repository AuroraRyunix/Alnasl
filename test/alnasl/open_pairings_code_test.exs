defmodule Alnasl.OpenPairingsCodeTest do
  @moduledoc """
  The connect code: one line, the address before the `#` and the secret
  after it, as pasted by somebody with a phone in the other hand.
  """

  use ExUnit.Case, async: true

  alias Alnasl.OpenPairings.Code

  # Made of pieces, so that nothing in this file looks like a secret.
  @secret "oplt" <> "_" <> String.duplicate("a", 43)

  test "the address is everything before the first #, the secret everything after" do
    assert Code.parse("https://pairings.example.org/api/boards/v1#" <> @secret) ==
             {:ok,
              %{
                root: "https://pairings.example.org/api/boards/v1",
                secret: @secret,
                kind: "tournament"
              }}
  end

  test "a group code says so, and a secret of another shape is taken as it is" do
    group = "oplg" <> "_" <> String.duplicate("b", 43)
    assert {:ok, %{kind: "group", secret: ^group}} = Code.parse("https://p.example/x#" <> group)

    # Opaque: the box does not judge what is after the #, the server does.
    assert {:ok, %{kind: nil, secret: "something#else"}} =
             Code.parse("https://p.example/x#something#else")
  end

  test "spaces and line breaks from a phone, a chat or a mail are dropped; so is a trailing slash" do
    pasted = "  https://pairings.example.org/api/boards/v1/ #\n  " <> @secret <> " \r\n"

    assert {:ok, %{root: "https://pairings.example.org/api/boards/v1", secret: @secret}} =
             Code.parse(pasted)
  end

  test "a desktop copy's code is loopback over plain http, and is used as written" do
    assert {:ok, %{root: "http://127.0.0.1:4000/api/boards/v1" = root}} =
             Code.parse("http://127.0.0.1:4000/api/boards/v1#" <> @secret)

    assert Code.loopback?(root)
    assert Code.host(root) == "127.0.0.1:4000"
    refute Code.loopback?("https://pairings.example.org/api/boards/v1")
    assert Code.host("https://pairings.example.org/api/boards/v1") == "pairings.example.org"
  end

  test "what is not a code is refused with a reason" do
    assert Code.parse("") == {:error, :empty}
    assert Code.parse(nil) == {:error, :empty}
    assert Code.parse("   \n ") == {:error, :empty}
    assert Code.parse("https://pairings.example.org/api/boards/v1") == {:error, :no_secret}
    assert Code.parse("https://pairings.example.org/api/boards/v1#") == {:error, :no_secret}
    assert Code.parse(@secret) == {:error, :no_secret}
    assert Code.parse("#" <> @secret) == {:error, :not_an_address}
    assert Code.parse("pairings.example.org/api#" <> @secret) == {:error, :not_an_address}
    assert Code.parse("ftp://pairings.example.org/api#" <> @secret) == {:error, :not_an_address}
  end
end
