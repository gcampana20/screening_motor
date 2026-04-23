-- Table: public.screening_list_entry

-- DROP TABLE IF EXISTS public.screening_list_entry cascade;

CREATE TABLE IF NOT EXISTS public.screening_list_entry
(
    id uuid NOT NULL DEFAULT uuid_generate_v4(),
    created_at timestamptz NOT NULL DEFAULT now(),
	updated_at timestamptz NOT NULL DEFAULT now(),
	list_id uuid NOT NULL,
	entry_type character varying,
	full_name character varying,
	birth_date date,
	country varchar,
	aliases jsonb,
	tax_id text,
	tax_id_normalized text,
	metadata jsonb,
	
	CONSTRAINT screening_list_entry_pkey PRIMARY KEY (id),
	CONSTRAINT screening_list_entry_list_id_fkey
        FOREIGN KEY (list_id) REFERENCES public.list(id)
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS public.screening_list_entry
    OWNER to postgres;
