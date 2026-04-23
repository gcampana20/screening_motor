-- Table: public.tenant

-- DROP TABLE IF EXISTS public.tenant;

CREATE TABLE IF NOT EXISTS public.tenant
(
    id uuid NOT NULL DEFAULT uuid_generate_v4(),
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    name character varying COLLATE pg_catalog."default" NOT NULL,
    CONSTRAINT tenant_pkey PRIMARY KEY (id)
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS public.tenant
    OWNER to postgres;

ALTER TABLE IF EXISTS public.tenant
    ENABLE ROW LEVEL SECURITY;