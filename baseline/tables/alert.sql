-- Table: public.alert

-- DROP TABLE IF EXISTS public.alert CASCADE;

CREATE TABLE IF NOT EXISTS public.alert
(
    id uuid NOT NULL DEFAULT uuid_generate_v4(),
    created_at timestamptz NOT NULL DEFAULT now(),
	updated_at timestamptz NOT NULL DEFAULT now(),
	name character varying,
  	type character varying,
  	person_id uuid,
  	company_id uuid,
  	tenant_id uuid NOT NULL,
  	screening_list_entry_id uuid,
	status character varying,
	analyst_id uuid,
	similarity_score numeric,
	detail character varying,
	
	CONSTRAINT alert_pkey PRIMARY KEY (id),
	
	CONSTRAINT alert_person_id_fkey
        FOREIGN KEY (person_id) REFERENCES public.person(id),
	CONSTRAINT alert_company_id_fkey
        FOREIGN KEY (company_id) REFERENCES public.company(id),
	CONSTRAINT alert_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES public.tenant(id),
	CONSTRAINT alert_screening_list_entry_id_fkey
        FOREIGN KEY (screening_list_entry_id) REFERENCES public.screening_list_entry(id),
	CONSTRAINT alert_analyst_id_fkey
        FOREIGN KEY (analyst_id) REFERENCES public.analyst(id),
	
	CONSTRAINT alert_owner_check CHECK (
        (person_id IS NOT NULL AND company_id IS NULL) OR
        (person_id IS NULL AND company_id IS NOT NULL)
	),
	CONSTRAINT alert_status_check CHECK (
		status IN ('PENDING', 'REVIEWING', 'CONFIRMED', 'DISMISSED')
	)
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS public.alert
    OWNER to postgres;
