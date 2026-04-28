enum RetailerId { amazon, ebay, walmart }

class Retailer {
  const Retailer({required this.id, required this.name, required this.url});

  final RetailerId id;
  final String name;
  final String url;
}
