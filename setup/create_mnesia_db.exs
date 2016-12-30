:ok = :mnesia.create_schema([node])
:ok = :mnesia.start()
{:atomic, :ok} = :mnesia.create_table(ContentLength, [attributes: [:path, :content_length],
                                                      disc_copies: [node]])
