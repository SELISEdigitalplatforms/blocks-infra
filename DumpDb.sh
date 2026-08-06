# mongodump --host localhost --port 27018 \
#   -u root -p 'root' --authenticationDatabase admin \
#   --db BlocksRootDb --out /tmp/mongodump_out --verbose

mongodump \
  --uri "mongodb://${MONGO_USER}:${MONGO_PASS}@localhost:27018/?authSource=admin" \
  --db BlocksConfiguration \
  --out /tmp/mongodump_out \
  --verbose
