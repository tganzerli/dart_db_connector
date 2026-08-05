// TechEmpower seed for MongoDB (mirrors schema_mysql.sql).
// Deterministic so repetitions stay comparable.
//   world:   { _id: 1..10000, randomnumber: [1,10000] }
//   fortune: { _id: 1..12,    message: <12 canônicas TechEmpower> }
// Uso: mongosh "mongodb://host:27017/teste" bench/http/seed_mongo.js
//
// randomnumber is deterministic: a simple LCG seeded from _id, so the dataset
// does not depend on the server RNG and is identical in any environment.
const dbh = db.getSiblingDB('teste');
dbh.world.drop();
dbh.fortune.drop();

const world = [];
for (let id = 1; id <= 10000; id++) {
  // Deterministic LCG: (a*id + c) mod m, mapped onto [1,10000].
  const r = ((1103515245 * id + 12345) % 2147483648);
  world.push({ _id: id, randomnumber: (r % 10000) + 1 });
}
dbh.world.insertMany(world, { ordered: false });

dbh.fortune.insertMany([
  { _id: 1,  message: 'fortune: No such file or directory' },
  { _id: 2,  message: "A computer scientist is someone who fixes things that aren't broken." },
  { _id: 3,  message: 'After enough decimal places, nobody gives a damn.' },
  { _id: 4,  message: 'A bad random number generator: 1, 1, 1, 1, 1, 4.33e+67, 1, 1, 1' },
  { _id: 5,  message: 'A computer program does what you tell it to do, not what you want it to do.' },
  { _id: 6,  message: 'Emacs is a nice operating system, but I prefer UNIX. — Tom Christiansen' },
  { _id: 7,  message: 'Any program that runs right is obsolete.' },
  { _id: 8,  message: 'A list is only as strong as its weakest link. — Donald Knuth' },
  { _id: 9,  message: 'Feature: A bug with seniority.' },
  { _id: 10, message: 'Computers make very fast, very accurate mistakes.' },
  { _id: 11, message: '<script>alert("This should not be displayed in a browser alert box.");</script>' },
  { _id: 12, message: 'フレームワークのベンチマーク' },
], { ordered: false });

print('[seed_mongo] world=' + dbh.world.countDocuments() + ' fortune=' + dbh.fortune.countDocuments());
