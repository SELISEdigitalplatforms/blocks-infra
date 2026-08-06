mongodump \
  --uri "mongodb://${MONGO_USER}:${MONGO_PASS}@localhost:27018/?authSource=admin" \
  --db BlocksRootDb\
  --collection ProjectPeoples \
  --out /tmp/mongodump_out \
  --verbose