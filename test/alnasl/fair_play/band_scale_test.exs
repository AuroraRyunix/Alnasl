defmodule Alnasl.FairPlay.BandScaleTest do
  use ExUnit.Case, async: true

  alias Alnasl.FairPlay.BandScale

  test "a big band keeps its own scale, a small one is pulled to everybody's" do
    :rand.seed(:exsss, {3, 1, 4})

    # 2000 events of a well-behaved band, 20 of a band that runs hot.
    big = for _ <- 1..2000, do: {2000, :rand.normal()}
    small = for _ <- 1..20, do: {1000, 1.0 + 2.0 * :rand.normal()}

    scale = BandScale.fit(big ++ small)

    {m_big, sd_big, 2000} = scale.bands[2000]
    assert_in_delta m_big, 0.0, 0.1
    assert_in_delta sd_big, 1.0, 0.1

    # 20 against k = 50: mostly the overall location and spread.
    {m_small, sd_small, 20} = scale.bands[1000]
    assert m_small > 0.1 and m_small < 0.6
    assert sd_small > 1.0 and sd_small < 1.8

    # The threshold of the hot band is higher than the plain 3.
    assert BandScale.threshold(scale, 1000, 3.0) > BandScale.threshold(scale, 2000, 3.0)

    # Adjusting is the same thing as moving the threshold.
    s = BandScale.threshold(scale, 1000, 3.0)
    assert_in_delta BandScale.adjust(scale, 1000, s), 3.0, 1.0e-12

    # A band never seen gets everybody's scale.
    {m, sd, _} = scale.global
    assert_in_delta BandScale.adjust(scale, 2800, m + sd), 1.0, 1.0e-12
  end

  test "the json keeps k and every band" do
    json = BandScale.fit([{1000, 1.0}, {1000, 2.0}, {1200, 0.0}]) |> BandScale.to_json()
    assert json["k"] == 50
    assert Map.keys(json["bands"]) == ["1000", "1200"]
  end
end
