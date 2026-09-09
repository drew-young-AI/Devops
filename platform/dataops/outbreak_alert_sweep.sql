WITH w AS (
  SELECT d.code AS disease, f.geo_code, tp.epi_year, tp.epi_week,
         SUM(f.value)::float/NULLIF(SUM(f.denominator),0) AS rate, SUM(f.value) AS cases
  FROM surveillance_fact f JOIN metric m ON m.metric_id=f.metric_id
  JOIN time_period tp ON tp.period_id=f.period_id JOIN disease d ON d.disease_id=f.disease_id
  WHERE m.code='nhi_visits' AND tp.time_level='epi_week' AND f.visit_type='門診'
  GROUP BY 1,2,3,4
), y AS (
  SELECT c.disease,c.geo_code,c.epi_year,c.epi_week,c.rate,p.rate prev_rate,
         c.rate/NULLIF(p.rate,0) AS ratio
  FROM w c JOIN w p ON p.disease=c.disease AND p.geo_code=c.geo_code
       AND p.epi_year=c.epi_year-1 AND p.epi_week=c.epi_week
  WHERE p.cases >= 20
), nxt AS (
  SELECT y.*, n.rate AS rate_next
  FROM y LEFT JOIN w n ON n.disease=y.disease AND n.geo_code=y.geo_code
       AND ((n.epi_year=y.epi_year AND n.epi_week=y.epi_week+1)
         OR (n.epi_year=y.epi_year+1 AND y.epi_week>=52 AND n.epi_week=1))
)
SELECT t.thr AS threshold,
       count(*) FILTER (WHERE ratio >= t.thr) AS alerts,
       round(100.0*count(*) FILTER (WHERE ratio >= t.thr)/count(*),2) AS pct_of_cells,
       round(100.0*count(*) FILTER (WHERE ratio >= t.thr AND rate_next > rate)
             / NULLIF(count(*) FILTER (WHERE ratio >= t.thr AND rate_next IS NOT NULL),0),1)
         AS pct_still_rising
FROM nxt, (VALUES (1.5),(2.0),(2.5),(3.0),(4.0),(6.0)) AS t(thr)
GROUP BY t.thr ORDER BY t.thr;
