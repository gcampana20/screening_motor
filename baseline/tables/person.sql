-- Table: public.person

-- DROP TABLE IF EXISTS public.person;

CREATE TABLE IF NOT EXISTS public.person
(
    id uuid NOT NULL DEFAULT uuid_generate_v4(),
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    tenant_id uuid,
    first_name character varying COLLATE pg_catalog."default" NOT NULL,
    last_name character varying COLLATE pg_catalog."default" NOT NULL,
    birth_date date,
    tax_id bigint,
    nacionality character varying COLLATE pg_catalog."default",
    CONSTRAINT person_pkey PRIMARY KEY (id),
    CONSTRAINT person_tenant_id_fkey FOREIGN KEY (tenant_id)
        REFERENCES public.tenant (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS public.person
    OWNER to postgres;

ALTER TABLE IF EXISTS public.person
    ENABLE ROW LEVEL SECURITY;