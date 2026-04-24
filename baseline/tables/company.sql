-- Table: public.company

-- DROP TABLE IF EXISTS public.company CASCADE;

CREATE TABLE IF NOT EXISTS public.company
(
    id uuid NOT NULL DEFAULT uuid_generate_v4(),
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    tenant_id uuid NOT NULL,
    name character varying COLLATE pg_catalog."default" NOT NULL,
    tax_id bigint,
    country character varying COLLATE pg_catalog."default",
    CONSTRAINT company_pkey PRIMARY KEY (id),
    CONSTRAINT company_tenant_id_fkey FOREIGN KEY (tenant_id)
        REFERENCES public.tenant (id) MATCH SIMPLE
        ON UPDATE NO ACTION
        ON DELETE NO ACTION
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS public.company
    OWNER to postgres;