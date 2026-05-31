# frozen_string_literal: true

module PayCore
  module Solana
    # Pure-Ruby BLAKE3 hasher (32-byte digest) used by the payment-channels
    # distribution hash. The Rust spine uses the `blake3` crate
    # (`rust/crates/mpp/src/program/payment_channels.rs:distribution_hash`); the
    # gem cannot add a native dependency, so the algorithm is implemented here.
    #
    # Scope: this is a straight BLAKE3 hash (no keyed mode, no key-derivation
    # context). It supports incremental `update` + a final 32-byte `digest`,
    # which is all `distribution_hash` needs. Verified against the BLAKE3
    # reference test vectors in `test/blake3_test.rb`.
    class Blake3
      OUT_LEN = 32
      BLOCK_LEN = 64
      CHUNK_LEN = 1024

      # Domain-separation flags.
      CHUNK_START = 1 << 0
      CHUNK_END = 1 << 1
      PARENT = 1 << 2
      ROOT = 1 << 3

      IV = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
      ].freeze

      MSG_PERMUTATION = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8].freeze

      MASK32 = 0xFFFFFFFF

      def initialize
        @chunk_state = ChunkState.new(IV, 0, 0)
        @cv_stack = []
        @cv_stack_len = 0
      end

      # Feed bytes into the hasher. Accepts a binary String.
      def update(input)
        input = input.b
        offset = 0
        len = input.bytesize
        while offset < len
          if @chunk_state.len == CHUNK_LEN
            chunk_cv = @chunk_state.output.chaining_value
            total_chunks = @chunk_state.chunk_counter + 1
            add_chunk_chaining_value(chunk_cv, total_chunks)
            @chunk_state = ChunkState.new(IV, total_chunks, 0)
          end
          want = CHUNK_LEN - @chunk_state.len
          take = [want, len - offset].min
          @chunk_state.update(input.byteslice(offset, take))
          offset += take
        end
        self
      end

      # Finalize and return the 32-byte digest as a binary String.
      def digest
        output = @chunk_state.output
        parent_nodes_remaining = @cv_stack_len
        while parent_nodes_remaining > 0
          parent_nodes_remaining -= 1
          output = parent_output(
            @cv_stack[parent_nodes_remaining],
            output.chaining_value_words,
            IV,
            0
          )
        end
        output.root_output_bytes(OUT_LEN)
      end

      # One-shot convenience hash.
      def self.hash(input)
        new.update(input).digest
      end

      # ── Compression function (shared by Output / ChunkState) ──

      class << self
        # Permute + compress a block of 16 message words into 8 chaining words.
        def compress(chaining_value, block_words, counter, block_len, flags)
          counter_low = counter & MASK32
          counter_high = (counter >> 32) & MASK32
          state = [
            chaining_value[0], chaining_value[1], chaining_value[2], chaining_value[3],
            chaining_value[4], chaining_value[5], chaining_value[6], chaining_value[7],
            IV[0], IV[1], IV[2], IV[3],
            counter_low, counter_high, block_len & MASK32, flags & MASK32
          ]
          block = block_words.dup

          7.times do |round|
            round_fn(state, block)
            block = permute(block) unless round == 6
          end

          8.times do |i|
            state[i] ^= state[i + 8]
            state[i + 8] ^= chaining_value[i]
          end
          state
        end

        private

        def permute(block)
          MSG_PERMUTATION.map { |index| block[index] }
        end

        def round_fn(state, m)
          g(state, 0, 4, 8, 12, m[0], m[1])
          g(state, 1, 5, 9, 13, m[2], m[3])
          g(state, 2, 6, 10, 14, m[4], m[5])
          g(state, 3, 7, 11, 15, m[6], m[7])
          g(state, 0, 5, 10, 15, m[8], m[9])
          g(state, 1, 6, 11, 12, m[10], m[11])
          g(state, 2, 7, 8, 13, m[12], m[13])
          g(state, 3, 4, 9, 14, m[14], m[15])
        end

        def g(state, a, b, c, d, mx, my)
          state[a] = (state[a] + state[b] + mx) & MASK32
          state[d] = rotr32(state[d] ^ state[a], 16)
          state[c] = (state[c] + state[d]) & MASK32
          state[b] = rotr32(state[b] ^ state[c], 12)
          state[a] = (state[a] + state[b] + my) & MASK32
          state[d] = rotr32(state[d] ^ state[a], 8)
          state[c] = (state[c] + state[d]) & MASK32
          state[b] = rotr32(state[b] ^ state[c], 7)
        end

        def rotr32(value, bits)
          value &= MASK32
          ((value >> bits) | (value << (32 - bits))) & MASK32
        end
      end

      private

      def add_chunk_chaining_value(new_cv, total_chunks)
        new_cv_words = words_from_bytes(new_cv)
        while (total_chunks & 1) == 0
          new_cv_words = parent_cv(@cv_stack[@cv_stack_len - 1], new_cv_words, IV, 0)
          @cv_stack_len -= 1
          total_chunks >>= 1
        end
        @cv_stack[@cv_stack_len] = new_cv_words
        @cv_stack_len += 1
      end

      def parent_cv(left_words, right_words, key_words, flags)
        parent_output(left_words, right_words, key_words, flags).chaining_value_words
      end

      def parent_output(left_words, right_words, key_words, flags)
        block_words = left_words + right_words
        Output.new(key_words.dup, block_words, 0, BLOCK_LEN, flags | PARENT)
      end

      def words_from_bytes(bytes)
        bytes.unpack("L<8")
      end

      # A 64-byte block awaiting compression along with the chaining state.
      class Output
        def initialize(input_chaining_value, block_words, counter, block_len, flags)
          @input_chaining_value = input_chaining_value
          @block_words = block_words
          @counter = counter
          @block_len = block_len
          @flags = flags
        end

        def chaining_value_words
          Blake3.compress(@input_chaining_value, @block_words, @counter, @block_len, @flags)[0, 8]
        end

        def chaining_value
          chaining_value_words.pack("L<8")
        end

        def root_output_bytes(out_len)
          output = +""
          output_block_counter = 0
          while output.bytesize < out_len
            words = Blake3.compress(
              @input_chaining_value, @block_words, output_block_counter, @block_len, @flags | ROOT
            )
            output << words.pack("L<16")
            output_block_counter += 1
          end
          output.byteslice(0, out_len)
        end
      end

      # Accumulates up to CHUNK_LEN bytes, compressing block-by-block.
      class ChunkState
        attr_reader :chunk_counter, :len

        def initialize(key_words, chunk_counter, flags)
          @chaining_value = key_words.dup
          @chunk_counter = chunk_counter
          @block = +"".b
          @blocks_compressed = 0
          @flags = flags
          @len = 0
        end

        def start_flag
          (@blocks_compressed == 0) ? CHUNK_START : 0
        end

        def update(input)
          offset = 0
          len = input.bytesize
          while offset < len
            if @block.bytesize == BLOCK_LEN
              block_words = @block.unpack("L<16")
              @chaining_value = Blake3.compress(
                @chaining_value, block_words, @chunk_counter, BLOCK_LEN, @flags | start_flag
              )[0, 8]
              @blocks_compressed += 1
              @block = +"".b
            end
            want = BLOCK_LEN - @block.bytesize
            take = [want, len - offset].min
            @block << input.byteslice(offset, take)
            offset += take
            @len += take
          end
        end

        def output
          block = @block + ("\x00".b * (BLOCK_LEN - @block.bytesize))
          block_words = block.unpack("L<16")
          Blake3::Output.new(
            @chaining_value, block_words, @chunk_counter, @block.bytesize,
            @flags | start_flag | Blake3::CHUNK_END
          )
        end
      end
    end
  end
end
