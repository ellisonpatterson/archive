require "pg"
require "uuid"
require "./archive/*"

CONFIG = Config.from_yaml(File.read("config/config.yml"))

PG_URL = URI.new(
  scheme: "postgres",
  user: CONFIG.db[:user],
  password: CONFIG.db[:password],
  host: CONFIG.db[:host],
  port: CONFIG.db[:port],
  path: CONFIG.db[:dbname],
)

PG_DB      = DB.open PG_URL
BATCH_SIZE = 10000

PG_DB.exec("BEGIN WORK")
PG_DB.exec("DECLARE C CURSOR FOR SELECT ctid FROM videos")

count = PG_DB.query_one("SELECT COUNT(*) FROM batches", as: Int64)
PG_DB.exec("MOVE #{BATCH_SIZE * count} C")
puts "Skipped #{count} batches"

i = 0
loop do
  batch = PG_DB.query_all("FETCH #{BATCH_SIZE} FROM C", as: Slice(UInt8))
  batch = batch.map do |slice|
    major = IO::ByteFormat::BigEndian.decode(UInt32, slice)
    slice += 4
    minor = IO::ByteFormat::BigEndian.decode(UInt16, slice)

    "(#{major},#{minor})"
  end

  if batch.size < BATCH_SIZE
    break
  end

  if PG_DB.query_one?("SELECT EXISTS (SELECT true FROM batches WHERE start_ctid = $1)", batch[0], as: Bool)
    next
  end

  PG_DB.exec("INSERT INTO batches VALUES ($1, $2, $3, $4)", UUID.random, batch[0], batch[-1], false)
  i += 1

  print "Created #{i} new batches\r"
end

PG_DB.exec("COMMIT WORK")

puts "Created #{i} new batches."
