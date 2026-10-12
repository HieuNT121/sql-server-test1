/* SQLCMD manifest: each pipeline component lives in its own file. */
/* The advanced source fixtures must precede the pipeline objects; the validation suite depends on them. */
:r /seed/pipeline/03-advanced-salesdb.sql
:r /seed/pipeline/00_pipeline_objects.sql
:r /seed/pipeline/05_store_location_objects.sql
:r /seed/pipeline/60_conversion_validation_objects.sql
:r /seed/pipeline/10_usp_validate_sales_source.sql
:r /seed/pipeline/15_usp_extract_store_location_mapping.sql
:r /seed/pipeline/20_usp_refresh_daily_sales_summary.sql
:r /seed/pipeline/25_usp_aggregate_daily_store_sales.sql
:r /seed/pipeline/30_usp_refresh_customer_value_snapshot.sql
:r /seed/pipeline/40_usp_refresh_product_performance.sql
:r /seed/pipeline/50_usp_refresh_executive_kpis.sql
:r /seed/pipeline/61_usp_validate_conversion_fixtures.sql
:r /seed/pipeline/63_usp_publish_conversion_readiness.sql
:r /seed/pipeline/64_conversion_challenge_procedures.sql
:r /seed/pipeline/80_usp_execute_pipeline_step.sql
:r /seed/pipeline/90_usp_run_sales_analytics_pipeline.sql
:r /seed/pipeline/95_usp_run_conversion_validation_pipeline.sql
:r /seed/pipeline/99_register_and_run_pipeline.sql
:r /seed/pipeline/98_register_conversion_validation_pipeline.sql
