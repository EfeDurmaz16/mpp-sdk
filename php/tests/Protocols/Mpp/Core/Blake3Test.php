<?php

declare(strict_types=1);

namespace PayKit\Tests;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use PayKit\Protocols\Mpp\Core\Blake3;

final class Blake3Test extends TestCase
{
    /**
     * Official BLAKE3 test vectors (input is the byte sequence 0,1,...,250
     * repeating). These lock the pure-PHP implementation to the reference used
     * by the Rust `blake3` crate that the payment-channels program relies on.
     *
     * @return list<array{0:int,1:string}>
     */
    public static function vectors(): array
    {
        return [
            [0, 'af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262'],
            [1, '2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213'],
            [64, '4eed7141ea4a5cd4b788606bd23f46e212af9cacebacdc7d1f4c6dc7f2511b98'],
            [1023, '10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11'],
            [1024, '42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7'],
            [1025, 'd00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444'],
            [2048, 'e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a'],
            [3072, 'b98cb0ff3623be03326b373de6b9095218513e64f1ee2edd2525c7ad1e5cffd2'],
            [4096, '015094013f57a5277b59d8475c0501042c0b642e531b0a1c8f58d2163229e969'],
        ];
    }

    #[DataProvider('vectors')]
    public function testMatchesReferenceVectors(int $len, string $expectedHex): void
    {
        $input = '';
        for ($i = 0; $i < $len; $i++) {
            $input .= chr($i % 251);
        }
        self::assertSame($expectedHex, bin2hex(Blake3::hash($input)));
    }

    public function testEmptyInputHashesToReferenceConstant(): void
    {
        self::assertSame(
            'af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262',
            bin2hex(Blake3::hash('')),
        );
    }
}
