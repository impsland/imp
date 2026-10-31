CREATE INDEX items_new ON items (hidden, id DESC);

CREATE INDEX spent_challenges_expiry ON spent_challenges (expires_at);
