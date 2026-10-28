extends RefCounted
## A client link's round trip, in milliseconds: ENet's own measurement when the link is on
## ENet, and dot-server's heartbeat ping otherwise. 0 while neither knows.
##
## [b]Why not just `DotClientLink.ping_ms`.[/b] That is one heartbeat every two seconds,
## sent unreliable, and it is -1 until the first comes back -- once, through a real UDP
## relay (`headless_lossy`), eight seconds after connecting. Until then the clock believes
## the link is instant and leaves the flight time out of its input lead, so the commands
## arrive after their ticks and are thrown away while the player moves perfectly on their
## own screen: on a steady 55 ms each way, the server had the client's command for 46% of
## its ticks in the first three seconds, 102 of them late (`--ping-rtt`, the control).
## ENet times every acknowledged packet from the connect handshake on, so on ENet its
## number is right before the first snapshot lands (100% in time, 0 late). Read by duck
## typing, because a web build has no ENet class to name.
static func rtt_ms(link: Node) -> float:
	if link == null or not is_instance_valid(link):
		return 0.0

	var api := link.multiplayer
	var peer: Object = api.multiplayer_peer if api != null else null

	if peer != null and peer.has_method("get_peer") and ClassDB.class_exists(&"ENetPacketPeer"):
		var server: Object = peer.call("get_peer", 1)

		if server != null and server.has_method("get_statistic"):
			var stat := ClassDB.class_get_integer_constant(&"ENetPacketPeer", &"PEER_ROUND_TRIP_TIME")
			var rtt := float(server.call("get_statistic", stat))

			if rtt > 0.0:
				return rtt

	if link.has_method("ping_ms"):
		return float(maxi(0, int(link.call("ping_ms"))))

	return 0.0
