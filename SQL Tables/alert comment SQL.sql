-- Table: public.alert_comment

-- DROP TABLE IF EXISTS public.alert_comment CASCADE;

CREATE TABLE IF NOT EXISTS public.alert_comment
(
    id uuid NOT NULL DEFAULT uuid_generate_v4(),
    created_at timestamptz NOT NULL DEFAULT now(),
	updated_at timestamptz NOT NULL DEFAULT now(),
  	type character varying,
  	alert_id uuid,
	tenant_id uuid,
  	analyst_id uuid,
	comment character varying,
	
	CONSTRAINT alert_comment_pkey PRIMARY KEY (id),
	
	CONSTRAINT alert_comment_alert_id_fkey
        FOREIGN KEY (alert_id) REFERENCES public.alert(id),
	CONSTRAINT alert_comment_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES public.tenant(id),
	CONSTRAINT alert_comment_analyst_id_fkey
        FOREIGN KEY (analyst_id) REFERENCES public.analyst(id)
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS public.alert_comment
    OWNER to postgres;
