-- Table: public.alert_status_history

-- DROP TABLE IF EXISTS public.alert_status_history CASCADE;

CREATE TABLE IF NOT EXISTS public.alert_status_history
(
    id uuid NOT NULL DEFAULT uuid_generate_v4(),
    created_at timestamptz NOT NULL DEFAULT now(),
	updated_at timestamptz NOT NULL DEFAULT now(),
  	type character varying,
  	alert_id uuid,
  	prev_status character varying,
	new_status character varying,
	valid_from timestamp NOT NULL,
	valid_to timestamp,
	
	CONSTRAINT alert_status_history_pkey PRIMARY KEY (id),
	
	CONSTRAINT alert_status_history_alert_id_fkey
        FOREIGN KEY (alert_id) REFERENCES public.alert(id)
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS public.alert_status_history
    OWNER to postgres;
