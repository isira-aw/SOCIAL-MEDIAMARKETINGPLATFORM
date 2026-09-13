-- ============================================================================
-- A Personalized AI-Based Social Media Marketing Platform
-- PostgreSQL schema (DDL)
--
-- Design notes
--   * UUID primary keys everywhere (pgcrypto gen_random_uuid()).
--   * JSONB for model outputs and raw third-party payloads, so provider
--     response shapes can evolve without migrations.
--   * Every AI-produced artefact stores the prompt and model version used,
--     for reproducibility.
--   * Status columns are constrained; failed work is never silently lost.
--   * All workflow access is scoped by client_id.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

-- ---------------------------------------------------------------------------
-- users
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
    user_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email          citext,
    display_name   text        NOT NULL,
    role           text        NOT NULL DEFAULT 'owner'
                   CHECK (role IN ('owner', 'manager', 'reviewer', 'admin')),
    status         text        NOT NULL DEFAULT 'active'
                   CHECK (status IN ('active', 'suspended', 'deleted')),
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS users_email_uniq ON users (email) WHERE email IS NOT NULL;

-- ---------------------------------------------------------------------------
-- clients
--   allowed_platforms is the AUTHORITATIVE publication allow-list. It is the
--   only source the workflow trusts for routing; LLM output never reaches it.
--   platform_config holds non-secret per-platform identifiers only
--   (page_id, ig_user_id, whatsapp.phone_number_id, recipients, opt_in flag).
--   Access tokens live in the n8n credential store, never here.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clients (
    client_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           uuid        NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    business_name     text        NOT NULL,
    sector            text        NOT NULL,
    description       text        NOT NULL DEFAULT '',
    brand_voice       text        NOT NULL DEFAULT '',
    audience          text        NOT NULL DEFAULT '',
    objectives        jsonb       NOT NULL DEFAULT '[]'::jsonb,
    allowed_platforms text[]      NOT NULL DEFAULT '{}',
    platform_config   jsonb       NOT NULL DEFAULT '{}'::jsonb,
    status            text        NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active', 'paused', 'disabled')),
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT clients_allowed_platforms_known
        CHECK (allowed_platforms <@ ARRAY['facebook','instagram','whatsapp']::text[])
);
CREATE INDEX IF NOT EXISTS clients_user_idx   ON clients (user_id);
CREATE INDEX IF NOT EXISTS clients_sector_idx ON clients (sector);

-- ---------------------------------------------------------------------------
-- competitors  (client-nominated, public/authorised sources only)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS competitors (
    competitor_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id        uuid        NOT NULL REFERENCES clients(client_id) ON DELETE CASCADE,
    handle           text        NOT NULL,
    platform         text        NOT NULL
                     CHECK (platform IN ('facebook','instagram','whatsapp','other')),
    active           boolean     NOT NULL DEFAULT true,
    last_observed_at timestamptz,
    observed_summary jsonb,   -- themes, tone, posting_cadence, content_formats, engagement_patterns
    created_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (client_id, platform, handle)
);
CREATE INDEX IF NOT EXISTS competitors_client_idx ON competitors (client_id) WHERE active;

-- ---------------------------------------------------------------------------
-- campaigns
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS campaigns (
    campaign_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id           uuid        NOT NULL REFERENCES clients(client_id) ON DELETE CASCADE,
    brief               text        NOT NULL,
    requested_platforms jsonb       NOT NULL DEFAULT '[]'::jsonb,  -- advisory only
    duration_days       integer     NOT NULL DEFAULT 14
                        CHECK (duration_days BETWEEN 1 AND 90),
    intent_json         jsonb,
    strategy_json       jsonb,
    report_json         jsonb,
    status              text        NOT NULL DEFAULT 'pending'
                        CHECK (status IN (
                            'pending','processing','intent_parsed','research_complete',
                            'strategy_generated','content_generating','content_validated',
                            'scheduled','publishing','partially_published','published',
                            'analytics_pending','analytics_complete','needs_review',
                            'failed','completed')),
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS campaigns_client_idx  ON campaigns (client_id, created_at DESC);
CREATE INDEX IF NOT EXISTS campaigns_status_idx  ON campaigns (status);
CREATE INDEX IF NOT EXISTS campaigns_intent_gin  ON campaigns USING gin (intent_json);

-- ---------------------------------------------------------------------------
-- content_assets
--   prompt_used + model_version + image_model_version give full reproducibility.
--   Only rows with approved = true AND review_state = 'approved' are publishable.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS content_assets (
    asset_id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id         uuid        NOT NULL REFERENCES campaigns(campaign_id) ON DELETE CASCADE,
    asset_type          text        NOT NULL DEFAULT 'image_post'
                        CHECK (asset_type IN ('text','image','image_post','video')),
    platform            text        NOT NULL
                        CHECK (platform IN ('facebook','instagram','whatsapp')),
    body                jsonb       NOT NULL DEFAULT '{}'::jsonb,  -- caption, hashtags, cta, format
    storage_ref         text,
    prompt_used         jsonb,      -- image_prompt, negative_prompt, aspect_ratio, style
    model_version       text,       -- text model that produced the copy
    image_provider      text,
    image_model_version text,
    approved            boolean     NOT NULL DEFAULT false,
    review_state        text        NOT NULL DEFAULT 'pending'
                        CHECK (review_state IN ('pending','pending_image','approved','needs_review','rejected')),
    validation_errors   jsonb,
    planned_day         integer,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS assets_campaign_idx ON content_assets (campaign_id);
CREATE INDEX IF NOT EXISTS assets_review_idx   ON content_assets (review_state) WHERE review_state = 'needs_review';

-- ---------------------------------------------------------------------------
-- schedules
--   bin_score and rationale are persisted for auditability of the
--   engagement-informed scheduling heuristic.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS schedules (
    schedule_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    asset_id     uuid        NOT NULL REFERENCES content_assets(asset_id) ON DELETE CASCADE,
    platform     text        NOT NULL
                 CHECK (platform IN ('facebook','instagram','whatsapp')),
    scheduled_at timestamptz NOT NULL,
    bin_score    numeric(10,6),
    rationale    jsonb,
    status       text        NOT NULL DEFAULT 'scheduled'
                 CHECK (status IN ('scheduled','publishing','published','failed','blocked','not_configured','cancelled')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (asset_id, platform)
);
CREATE INDEX IF NOT EXISTS schedules_due_idx ON schedules (scheduled_at) WHERE status = 'scheduled';

-- ---------------------------------------------------------------------------
-- publications
--   UNIQUE (schedule_id, platform) is the duplicate-publication guard; the
--   publisher workflows upsert on it and the router refuses a second publish.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS publications (
    publication_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    schedule_id      uuid        NOT NULL REFERENCES schedules(schedule_id) ON DELETE CASCADE,
    platform         text        NOT NULL
                     CHECK (platform IN ('facebook','instagram','whatsapp','unknown')),
    platform_post_id text,
    published_at     timestamptz,
    status           text        NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending','published','failed','blocked','not_configured')),
    error_detail     jsonb,      -- {stage, platform, error_code, message, retry_count, timestamp}
    raw_response     jsonb,
    created_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (schedule_id, platform)
);
CREATE INDEX IF NOT EXISTS publications_status_idx    ON publications (status);
CREATE INDEX IF NOT EXISTS publications_published_idx ON publications (published_at DESC) WHERE status = 'published';
CREATE UNIQUE INDEX IF NOT EXISTS publications_platform_post_uniq
    ON publications (platform, platform_post_id) WHERE platform_post_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- analytics
--   Metrics the platform did not return stay NULL. They are never imputed.
--   insights holds the validated Engagement Agent and Analytics Agent JSON.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS analytics (
    analytic_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    publication_id   uuid        NOT NULL REFERENCES publications(publication_id) ON DELETE CASCADE,
    captured_at      timestamptz NOT NULL DEFAULT now(),
    impressions      integer CHECK (impressions IS NULL OR impressions >= 0),
    reach            integer CHECK (reach       IS NULL OR reach       >= 0),
    reactions        integer CHECK (reactions   IS NULL OR reactions   >= 0),
    comments         integer CHECK (comments    IS NULL OR comments    >= 0),
    shares           integer CHECK (shares      IS NULL OR shares      >= 0),
    engagement_score numeric(10,6) CHECK (engagement_score IS NULL OR engagement_score BETWEEN 0 AND 1),
    insights         jsonb,
    model_version    text,
    raw_payload      jsonb,
    UNIQUE (publication_id, captured_at)
);
CREATE INDEX IF NOT EXISTS analytics_pub_idx      ON analytics (publication_id);
CREATE INDEX IF NOT EXISTS analytics_captured_idx ON analytics (captured_at DESC);

-- ---------------------------------------------------------------------------
-- trends  (relative interest signals, not absolute demand)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS trends (
    trend_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id uuid        NOT NULL REFERENCES campaigns(campaign_id) ON DELETE CASCADE,
    keyword     text        NOT NULL,
    index_value numeric(6,2) NOT NULL DEFAULT 0,
    direction   text CHECK (direction   IS NULL OR direction   IN ('rising','stable','falling')),
    seasonality text CHECK (seasonality IS NULL OR seasonality IN ('seasonal','flat')),
    raw_payload jsonb,
    captured_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS trends_campaign_idx ON trends (campaign_id);

-- ---------------------------------------------------------------------------
-- review_queue  (human escalation: invalid intent, strategy, creative, assets)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS review_queue (
    review_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id uuid        NOT NULL REFERENCES campaigns(campaign_id) ON DELETE CASCADE,
    asset_id    uuid        REFERENCES content_assets(asset_id) ON DELETE CASCADE,
    stage       text        NOT NULL
                CHECK (stage IN ('intent','research','strategy','creative','image','publication','analytics')),
    reason      text        NOT NULL,
    payload     jsonb,
    state       text        NOT NULL DEFAULT 'open'
                CHECK (state IN ('open','in_review','resolved','dismissed')),
    resolved_by uuid REFERENCES users(user_id),
    created_at  timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz
);
CREATE INDEX IF NOT EXISTS review_open_idx ON review_queue (created_at DESC) WHERE state = 'open';

-- ---------------------------------------------------------------------------
-- interactions  (six-hourly comment / DM monitoring; candidates only)
--   author_hash is a truncated SHA-256 of the platform-scoped author id.
--   No end-consumer names, avatars or profile links are stored.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS interactions (
    interaction_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    publication_id    uuid        REFERENCES publications(publication_id) ON DELETE SET NULL,
    client_id         uuid        NOT NULL REFERENCES clients(client_id) ON DELETE CASCADE,
    platform          text        NOT NULL CHECK (platform IN ('facebook','instagram','whatsapp')),
    interaction_type  text        NOT NULL CHECK (interaction_type IN ('comment','dm','mention')),
    external_id       text        NOT NULL,
    author_hash       text        NOT NULL,
    message           text        NOT NULL,
    received_at       timestamptz NOT NULL,
    classification    jsonb,
    draft_response    text,
    review_state      text        NOT NULL DEFAULT 'pending_review'
                      CHECK (review_state IN ('pending_review','approved','rejected','sent')),
    reviewed_by       uuid REFERENCES users(user_id),
    model_version     text,
    validation_errors jsonb,
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (platform, external_id)
);
CREATE INDEX IF NOT EXISTS interactions_pending_idx ON interactions (client_id, received_at DESC)
    WHERE review_state = 'pending_review';

-- ---------------------------------------------------------------------------
-- updated_at maintenance
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['users','clients','campaigns','content_assets','schedules'] LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS %I_set_updated_at ON %I; '
            'CREATE TRIGGER %I_set_updated_at BEFORE UPDATE ON %I '
            'FOR EACH ROW EXECUTE FUNCTION set_updated_at();', t, t, t, t);
    END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- Convenience view: historical engagement feed for future campaigns
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_client_engagement_history AS
SELECT c.client_id,
       p.platform,
       p.published_at,
       a.impressions, a.reach, a.reactions, a.comments, a.shares,
       a.engagement_score,
       ca.body ->> 'format' AS content_format,
       cam.campaign_id
FROM analytics a
JOIN publications   p   ON p.publication_id = a.publication_id
JOIN schedules      s   ON s.schedule_id    = p.schedule_id
JOIN content_assets ca  ON ca.asset_id      = s.asset_id
JOIN campaigns      cam ON cam.campaign_id  = ca.campaign_id
JOIN clients        c   ON c.client_id      = cam.client_id
WHERE p.status = 'published';
