// The binary catalog and Home's slice the app bundles, from the compact JSON
// (owner, 2026-10-11: launches were parsing ~98 MB of JSON the first time after
// every update). Compiled together with the app's own catalog code, so the
// files are exactly what the app reads:
//
//   swiftc -O Marracat/Models.swift Marracat/Stores/CatalogBinary.swift \
//       Marracat/Stores/HomeSlice.swift scripts/catalog_binary/main.swift -o build/catalog-binary
//   build/catalog-binary Marracat/Resources/catalog-compact.json Marracat/Resources
//
// catalog/make_compact.py runs it after writing the JSON. It reads both files
// back and checks them against the JSON before it reports success.
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: catalog-binary <catalog-compact.json> <out dir>\n".utf8))
    exit(2)
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("catalog-binary: \(message)\n".utf8))
    exit(1)
}

let json = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2], isDirectory: true)
guard let data = try? Data(contentsOf: json) else { fail("can't read \(json.path)") }
let decoder = JSONDecoder()
if !data.starts(with: Data(#"{"generatedAt""#.utf8)) { decoder.keyDecodingStrategy = .convertFromSnakeCase }
let catalog: Catalog
do { catalog = try decoder.decode(Catalog.self, from: data) } catch { fail("\(json.lastPathComponent) doesn't decode: \(error)") }
guard !catalog.products.isEmpty else { fail("no products") }

let full = try CatalogBinary.encode(catalog)
let slice = HomeSlice.make(catalog)
let home = try CatalogBinary.encode(slice)

// Read back exactly as the app will before anything is written.
guard let back = CatalogBinary.decode(full), back.generatedAt == catalog.generatedAt,
      back.products == catalog.products, back.brands == catalog.brands,
      back.categories == catalog.categories, back.subcategories == catalog.subcategories else {
    fail("the binary catalog doesn't read back as the JSON")
}
guard let homeBack = CatalogBinary.decode(home), homeBack.products == slice.products,
      homeBack.generatedAt == catalog.generatedAt else { fail("the home slice doesn't read back") }

do {
    try full.write(to: out.appendingPathComponent("catalog.bin"), options: .atomic)
    try home.write(to: out.appendingPathComponent("catalog-home.bin"), options: .atomic)
} catch { fail("can't write: \(error)") }
print(String(format: "binary: %d products, %.0f MB; home slice: %d products, %.1f MB",
             catalog.products.count, Double(full.count) / 1e6, slice.products.count, Double(home.count) / 1e6))
