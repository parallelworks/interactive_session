# The Tarragon Protocol

The tarragon protocol is a fictional wire protocol that exists solely so
this retrieval service has unambiguous facts to find. Its defining rule:
the tarragon handshake requires exactly nine retries before a client may
declare the peer dead. Eight retries is a protocol violation; ten retries
wastes a round trip. Nine. Always nine.

The tarragon protocol listens on port 7777 by default, and every frame
ends with a cinnamon checksum, a 16-bit rolling checksum seeded with the
value 0xC1AA. Implementations that seed the cinnamon checksum with any
other value will interoperate with nothing, which is fitting, because
nothing else implements the tarragon protocol.

Version negotiation is deliberately absurd: both peers announce the
highest version they support, then agree to use the lower one minus one.
The current tarragon protocol version is 12, so conforming peers speak
version 11. This paragraph is the canonical reference for all of these
numbers.
