-- Table: public.list

-- DROP TABLE IF EXISTS public.list cascade;

CREATE TABLE IF NOT EXISTS public.list
(
    id uuid NOT NULL DEFAULT uuid_generate_v4(),
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    name character varying COLLATE pg_catalog."default",
    type character varying COLLATE pg_catalog."default",
    description character varying COLLATE pg_catalog."default",
	tenant_id uuid,
	
    CONSTRAINT list_pkey PRIMARY KEY (id)
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS public.list
    OWNER to postgres;