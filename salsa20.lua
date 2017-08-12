-- Copyright (c) 2017  Pierre Chapuis  -- see LICENSE file
------------------------------------------------------------
--[[

Salsa20 stream encryption

Pure Lua implementation of the salsa20 algorithm

]]

local app, concat = table.insert, table.concat

------------------------------------------------------------

-- salsa quarter round (rotl inlined)
local function qround(st,x,y,z,w)
	-- st is a salsa state: an array of 16 u32 words
	-- x,y,z,w are indices in st
	local a, b, c, d = st[x], st[y], st[z], st[w]
	local t
	t = (a + d) & 0xffffffff
	-- b = b ~ rotl32(t, 7)
	b = b ~ ((t << 7) | (t >> 25)) & 0xffffffff
	t = (b + a) & 0xffffffff
	-- c = c ~ rotl32(t, 9)
	c = c ~ ((t << 9) | (t >> 23)) & 0xffffffff
	t = (c + b) & 0xffffffff
	-- d = d ~ rotl32(t, 13)
	d = d ~ ((t << 13) | (t >> 19)) & 0xffffffff
	t = (d + c) & 0xffffffff
	-- a = a ~ rotl32(t, 18)
	a = a ~ ((t << 18) | (t >> 14)) & 0xffffffff
	st[x], st[y], st[z], st[w] = a, b, c, d
	return st
end

-- salsa20 state and working state are allocated once and reused
-- by each invocation of salsa20_block()
local salsa20_state = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}
local salsa20_working_state = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}

local salsa20_block = function(key, counter, nonce)
	-- key: u32[8]
	-- counter: u32
	-- nonce: u32[3]
	local st = salsa20_state 		-- state
	local wst = salsa20_working_state 	-- working state
	-- initialize state
	st[1], st[6], st[11], st[16] =
		0x61707865, 0x3320646e, 0x79622d32, 0x6b206574
	for i = 1, 4 do
		st[i+1] = key[i]
		st[i+11] = key[i+4]
	end
	st[7], st[8], st[9], st[10] = nonce[1], nonce[2], counter, 0
	-- copy state to working_state
	for i = 1, 16 do wst[i] = st[i] end
	-- run 20 rounds, ie. 10 iterations of 8 quarter rounds
	for i = 1, 10 do           --RFC reference:
		qround(wst, 1,5,9,13)    --1.  QUARTERROUND ( 0, 4, 8,12)
		qround(wst, 6,10,14,2)   --2.  QUARTERROUND ( 5, 9,13, 1)
		qround(wst, 11,15,3,7)   --3.  QUARTERROUND (10,14, 2, 6)
		qround(wst, 16,4,8,12)   --4.  QUARTERROUND (15, 3, 7,11)
		qround(wst, 1,2,3,4)     --5.  QUARTERROUND ( 0, 1, 2, 3)
		qround(wst, 6,7,8,5)     --6.  QUARTERROUND ( 5, 6, 7, 4)
		qround(wst, 11,12,9,10)  --7.  QUARTERROUND (10,11, 8, 9)
		qround(wst, 16,13,14,15) --8.  QUARTERROUND (15,12,13,14)
	end
	-- add working_state to state
	for i = 1, 16 do st[i] = (st[i] + wst[i]) & 0xffffffff end
	-- return st, an array of 16 u32 words used as a keystream
	return st
end --salsa20_block()

-- pat16: used to unpack a 64-byte string as 16 uint32
local pat16 = "<I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4"

local function salsa20_encrypt_block(key, counter, nonce, pt, ptidx)
	-- encrypt a 64-byte block of plain text.
	-- key: 32 bytes as an array of 8 uint32
	-- counter: an uint32 (must be incremented for each block)
	-- nonce: 8 bytes as an array of 2 uint32
	-- pt: plain text string,
	-- ptidx: index of beginning of block in plain text (origin=1)
	-- if less than 64 bytes are left at position ptidx, it is padded
	--    with null bytes before encryption and result is stripped
	--    accordingly.
	-- return encrypted block as a string  (length <= 16)
	local rbn = #pt - ptidx + 1 -- number of remaining bytes in pt
	if rbn < 64 then
		local tmp = string.sub(pt, ptidx)
		pt = tmp .. string.rep('\0', 64 - rbn) --pad last block
		ptidx = 1
	end
	assert(#pt >= 64)
	local ba = table.pack(string.unpack(pat16, pt, ptidx))
	local keystream = salsa20_block(key, counter, nonce)
	for i = 1, 16 do
		ba[i] = ba[i] ~ keystream[i]
	end
	local es = string.pack(pat16, table.unpack(ba))
	if rbn < 64 then
		es = string.sub(es, 1, rbn)
	end
	return es
end --salsa20_encrypt_block

local salsa20_encrypt = function(key, counter, nonce, pt)
	-- encrypt plain text 'pt', return encrypted text
	-- key: 32 bytes as a string
	-- counter: an uint32 (must be incremented for each block)
	-- nonce: 8 bytes as a string
	-- pt: plain text string,

	-- Ensure counter can fit an uint32 --although it's unlikely
	-- that we hit this wall with pure Lua encryption :-)
	assert((counter + #pt // 64 + 1) < 0xffffffff,
		"block counter must fit an uint32")
	assert(#key == 32, "#key must be 32")
	assert(#nonce == 8, "#nonce must be 8")
	local keya = table.pack(string.unpack("<I4I4I4I4I4I4I4I4", key))
	local noncea = table.pack(string.unpack("<I4I4", nonce))
	local t = {} -- used to collect all encrypted blocks
	local ptidx = 1
	while ptidx < #pt do
		app(t, salsa20_encrypt_block(keya, counter, noncea, pt, ptidx))
		ptidx = ptidx + 64
		counter = counter + 1
	end
	local et = concat(t)
	return et
end --salsa20_encrypt()

------------------------------------------------------------
return {
	encrypt = salsa20_encrypt,
	decrypt = salsa20_encrypt,
	--
	key_size = 32,
	nonce_size = 8,
	}

--end of salsa20