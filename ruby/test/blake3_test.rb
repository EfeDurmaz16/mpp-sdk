# frozen_string_literal: true

require_relative "test_helper"

# Golden-vector tests for the pure-Ruby BLAKE3 hasher backing the
# payment-channels distribution hash. Vectors are from the official BLAKE3
# reference (`test_vectors.json`): input byte i is `i % 251`.
class Blake3Test < Minitest::Test
  B = ::PayCore::Solana::Blake3

  # Reference input: bytes 0,1,2,... each mod 251.
  def reference_input(length)
    (0...length).map { |i| i % 251 }.pack("C*")
  end

  REFERENCE_VECTORS = {
    0 => "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262",
    1 => "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213",
    63 => "e9bc37a594daad83be9470df7f7b3798297c3d834ce80ba85d6e207627b7db7b",
    64 => "4eed7141ea4a5cd4b788606bd23f46e212af9cacebacdc7d1f4c6dc7f2511b98",
    65 => "de1e5fa0be70df6d2be8fffd0e99ceaa8eb6e8c93a63f2d8d1c30ecb6b263dee",
    1023 => "10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11",
    1024 => "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7",
    1025 => "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444",
    2048 => "e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a",
    3072 => "b98cb0ff3623be03326b373de6b9095218513e64f1ee2edd2525c7ad1e5cffd2",
    4096 => "015094013f57a5277b59d8475c0501042c0b642e531b0a1c8f58d2163229e969"
  }.freeze

  def test_reference_vectors
    REFERENCE_VECTORS.each do |length, expected|
      digest = B.hash(reference_input(length))
      assert_equal expected, digest.unpack1("H*"), "BLAKE3 mismatch for #{length}-byte input"
    end
  end

  def test_empty_input_via_incremental_update
    hasher = B.new
    hasher.update("")
    assert_equal REFERENCE_VECTORS[0], hasher.digest.unpack1("H*")
  end

  def test_incremental_update_matches_one_shot
    input = reference_input(2048)
    hasher = B.new
    offset = 0
    while offset < input.bytesize
      hasher.update(input.byteslice(offset, 7))
      offset += 7
    end
    assert_equal B.hash(input).unpack1("H*"), hasher.digest.unpack1("H*")
  end

  def test_digest_is_32_bytes
    assert_equal 32, B.hash("hello").bytesize
  end
end
