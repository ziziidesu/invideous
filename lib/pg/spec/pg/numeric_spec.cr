require "../spec_helper"
require "../../src/pg_ext/big_rational"

private def n(nd, w, s, ds, d)
  PG::Numeric.new(nd.to_i16, w.to_i16, s.to_i16, ds.to_i16, d.map(&.to_i16))
end

private def br(n, d)
  BigRational.new(n, d)
end

private def ex(which)
  case which
  when "nan"
    n(0, 0, -16384, 0, [] of Int16)
  when "0"
    n(0, 0, 0, 0, [] of Int16)
  when "0.0"
    n(0, 0, 0, 1, [] of Int16)
  when "1"
    n(1, 0, 0, 0, [1])
  when "-1"
    n(1, 0, 0x4000, 0, [1])
  when "1.3"
    n(2, 0, 0, 1, [1, 3000])
  when "1.30"
    n(2, 0, 0, 2, [1, 3000])
  when "12345.6789123"
    n(4, 1, 0, 7, [1, 2345, 6789, 1230])
  when "-0.00009"
    n(1, -2, 0x4000, 5, [9000])
  when "-0.000009"
    n(1, -2, 0x4000, 6, [900])
  when "-0.0000009"
    n(1, -2, 0x4000, 7, [90])
  when "-0.00000009"
    n(1, -2, 0x4000, 8, [9])
  when "0.0...9"
    n(2, -10, 0, 43, [9999, 9990])
  when "800000"
    n(1, 1, 0, 0, [80])
  when "50093"
    n(2, 1, 0, 0, [5, 93])
  when "500000093"
    n(3, 2, 0, 0, [5, 0, 93])
  when "0.3"
    n(1, -1, 0, 1, [3000])
  when "0.03"
    n(1, -1, 0, 2, [300])
  when "0.003"
    n(1, -1, 0, 3, [30])
  when "0.000300003"
    n(3, -1, 0, 9, [3, 0, 3000])
  when "0.0000006000000"
    n(1, -2, 0, 13, [60])
  when "50093.60754417"
    n(4, 1, 0, 8, [5, 93, 6075, 4417])
  else
    raise "no example #{which}"
  end
end

describe PG::Numeric do
  it "#to_f" do
    [
      {"nan", 0_f64},
      {"0", 0_f64},
      {"0.0", 0_f64},
      {"1", 1_f64},
      {"-1", -1_f64},
      {"1.3", 1.3_f64},
      {"1.30", 1.3_f64},
      {"12345.6789123", 12345.6789123_f64},
      {"-0.00009", -0.00009_f64},
      {"-0.000009", -0.000009_f64},
      {"-0.0000009", -0.0000009_f64},
      {"-0.00000009", -0.00000009_f64},
      {"0.0...9", 0.0000000000000000000000000000000000009999999_f64},
    ].each do |x|
      ex(x[0]).to_f.should be_close(x[1], 1e-50)
    end
  end

  it "#to_big_r" do
    [
      {"nan", br(0, 1)},
      {"0", br(0, 1)},
      {"0.0", br(0, 1)},
      {"1", br(1, 1)},
      {"-1", br(-1, 1)}, {"1.3", br(13, 10)},
      {"1.30", br(13, 10)},
      {"12345.6789123", br(123456789123, 10000000)},
      {"-0.00009", br(-9, 100000)},
      {"-0.000009", br(-9, 1000000)},
      {"-0.0000009", br(-9, 10000000)},
      {"-0.00000009", br(-9, 100000000)},
      {"0.0...9", br(BigInt.new(9999999), BigInt.new(10)**43)},
    ].each do |x|
      ex(x[0]).to_big_r.should eq(x[1])
    end
  end

  it "#to_s" do
    [
      {"nan", "NaN"},
      {"0", "0"},
      {"0.0", "0.0"},
      {"1", "1"},
      {"-1", "-1"},
      {"1.3", "1.3"},
      {"1.30", "1.30"},
      {"12345.6789123", "12345.6789123"},
      {"800000", "800000"},
      {"0.3", "0.3"},
      {"0.03", "0.03"},
      {"0.003", "0.003"},
      {"0.000300003", "0.000300003"},
      {"-0.00009", "-0.00009"},
      {"-0.000009", "-0.000009"},
      {"-0.0000009", "-0.0000009"},
      {"-0.00000009", "-0.00000009"},
      {"0.0...9", "0.0000000000000000000000000000000000009999999"},
      {"50093", "50093"},
      {"500000093", "500000093"},
      {"0.0000006000000", "0.0000006000000"},
      {"50093.60754417", "50093.60754417"},
    ].each do |x|
      ex(x[0]).to_s.should eq(x[1])
      ex(x[0]).inspect.should eq(x[1])
    end
  end

  it "#nan?" do
    ex("nan").nan?.should be_true
    ex("1").nan?.should be_false
    ex("-1").nan?.should be_false
  end
end
