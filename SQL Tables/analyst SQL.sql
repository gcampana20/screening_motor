-- Table: public.analyst

-- DROP TABLE IF EXISTS public.analyst CASCADE;

CREATE TABLE IF NOT EXISTS public.analyst
(
    id uuid NOT NULL DEFAULT uuid_generate_v4(),
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    name character varying NOT NULL,
	tenant_id uuid,

	CONSTRAINT analyst_pkey PRIMARY KEY (id),

	CONSTRAINT analyts_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES public.tenant(id)	
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS public.analyst
    OWNER to postgres;