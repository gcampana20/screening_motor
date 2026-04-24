-- Table: public.account

-- DROP TABLE IF EXISTS public.account;

CREATE TABLE IF NOT EXISTS public.account
(
    id uuid NOT NULL DEFAULT uuid_generate_v4(),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
	number integer not null,
	type character varying,
	status character varying,
	tenant_id uuid not null,
    person_id uuid,
    company_id uuid,
    
	CONSTRAINT account_pkey PRIMARY KEY (id),
	
	CONSTRAINT account_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES public.tenant(id),
    CONSTRAINT account_person_id_fkey
		FOREIGN KEY (person_id) REFERENCES public.person(id),
	CONSTRAINT account_company_id_fkey
		FOREIGN KEY (company_id) REFERENCES public.company(id),
	
	CONSTRAINT account_owner_check CHECK (
        (person_id IS NOT NULL AND company_id IS NULL) OR
        (person_id IS NULL AND company_id IS NOT NULL)
    )
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS public.account
    OWNER to postgres;
