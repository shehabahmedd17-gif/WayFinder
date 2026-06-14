// Google Places (New) Text Search result.
// py:search_places() return dict (lines 636-676).
class Place {
  final String name; // displayName.text
  final String address; // formattedAddress
  final double lat; // location.latitude
  final double lng; // location.longitude
  final String placeId; // id

  const Place({
    required this.name,
    required this.address,
    required this.lat,
    required this.lng,
    required this.placeId,
  });

  @override
  String toString() => 'Place($name @ $lat,$lng — $address)';
}
