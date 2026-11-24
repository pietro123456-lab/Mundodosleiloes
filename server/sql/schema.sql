CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE IF NOT EXISTS players (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 username text UNIQUE NOT NULL,
 password_hash text NOT NULL,
 coins bigint NOT NULL DEFAULT 1000 CHECK (coins >= 0),
 is_admin boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS inventory (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 player_id uuid NOT NULL REFERENCES players(id) ON DELETE CASCADE,
 item_name text NOT NULL,
 rarity text NOT NULL,
 mutation text NOT NULL DEFAULT 'Normal',
 income_per_second bigint NOT NULL DEFAULT 0,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS luck_state (
 player_id uuid PRIMARY KEY REFERENCES players(id) ON DELETE CASCADE,
 multiplier integer NOT NULL DEFAULT 1,
 expires_at timestamptz,
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS global_luck (
 id integer PRIMARY KEY DEFAULT 1 CHECK (id=1),
 multiplier integer NOT NULL DEFAULT 1,
 expires_at timestamptz
);
INSERT INTO global_luck(id) VALUES(1) ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS auctions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 seller_id uuid REFERENCES players(id),
 item_name text NOT NULL,
 rarity text NOT NULL,
 mutation text NOT NULL DEFAULT 'Normal',
 starting_bid bigint NOT NULL CHECK(starting_bid >= 0),
 current_bid bigint NOT NULL DEFAULT 0 CHECK(current_bid >= 0),
 highest_bidder uuid REFERENCES players(id),
 ends_at timestamptz NOT NULL,
 status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','closed')),
 created_at timestamptz NOT NULL DEFAULT now()
);
