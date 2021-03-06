WITH major_events AS (
SELECT
      SessionId,
      TimeStamp,
      CONCAT(ActionId, '~~', 'API_EVENT') AS ActionId,
      NULL AS CallingNumber,
      CustomerId,
      FlowName
FROM `cosmic-octane-88917.analytics_us._VW_ApiEvent`

UNION ALL

SELECT
      SessionId,
      TimeStamp,
      CONCAT(ActionId, '~~', 'CALL_EVENT', ':', CallAnswerIndicator) AS ActionId,
      CallingNumber,
      CustomerId,
      FlowName
FROM `cosmic-octane-88917.analytics_us._VW_CallEvent`
WHERE ActionId != 'TRANSFER_33'

UNION ALL

SELECT
      SessionId,
      TimeStamp,
      CONCAT(ActionId, '~~', CAST(DtmfInput AS STRING), '-dtmf') ActionId,
      NULL AS CallingNumber,
      CustomerId,
      FlowName
FROM `cosmic-octane-88917.analytics_us._VW_DtmfEvent`

UNION ALL

SELECT
      SessionId,
      TimeStamp,
      CONCAT(ActionId, '~~', 'MSG_EVENT') AS ActionId,
      NULL AS CallingNumber,
      CustomerId,
      FlowName
FROM `cosmic-octane-88917.analytics_us._VW_MsgEvent`

UNION ALL

SELECT
      SessionId,
      TimeStamp,
      CONCAT(ActionId, '~~', 'NLP_EVENT') AS ActionId,
      NULL AS CallingNumber,
      CustomerId,
      FlowName
FROM `cosmic-octane-88917.analytics_us._VW_NlpEvent`
),

filtered AS (
SELECT  SessionId,
        TimeStamp,
        ActionId,
        CallingNumber,
        FlowName
FROM major_events
WHERE FlowName in {0}
AND EXTRACT(DATE FROM TimeStamp) BETWEEN '{1}' AND '{2}'

),

tollfreenumbers AS (
SELECT '%800%' areacode, '.' matchkey
UNION ALL
SELECT '%888%' areacode, '.' matchkey
UNION ALL
SELECT '%877%' areacode, '.' matchkey
UNION ALL
SELECT '%866%' areacode, '.' matchkey
UNION ALL
SELECT '%855%' areacode, '.' matchkey
UNION ALL
SELECT '%844%' areacode, '.' matchkey
UNION ALL
SELECT '%833%' areacode, '.' matchkey
),

callback_subset AS (
SELECT DISTINCT *,
        CASE WHEN LEFT(CallingNumber, 6) LIKE tollfreenumbers.areacode THEN 1 ELSE 0 END AS TollFreeNumber,
        RANK() OVER(PARTITION BY CallingNumber ORDER BY TimeStamp) rank,
        TIMESTAMP_DIFF(TimeStamp, LAG(TimeStamp) OVER(PARTITION BY CallingNumber ORDER BY TimeStamp), DAY) days_since_last_call,
        LAG(session_duration) OVER(PARTITION BY CallingNumber ORDER BY TimeStamp) previous_duration
FROM (
        SELECT DISTINCT
                CallingNumber,
                SessionId,
                MIN(Timestamp) TimeStamp,
                TIMESTAMP_DIFF(MAX(TimeStamp), MIN(TimeStamp), SECOND) session_duration,
                '.' matchkey
        FROM filtered f
        WHERE CallingNumber != 'Restricted'
        AND CallingNumber IS NOT NULL
        GROUP BY CallingNumber, SessionId
     )
INNER JOIN tollfreenumbers USING(matchkey)
),

callbacks AS (
SELECT DISTINCT *,
        RANK() OVER(PARTITION BY CallingNumber ORDER BY TimeStamp) rank,
        TIMESTAMP_DIFF(TimeStamp, LAG(TimeStamp) OVER(PARTITION BY CallingNumber ORDER BY TimeStamp), DAY) days_since_last_call,
        LAG(session_duration) OVER(PARTITION BY CallingNumber ORDER BY TimeStamp) previous_duration
FROM (
      SELECT CallingNumber,
             SessionId,
             ANY_VALUE(TimeStamp) TimeStamp,
             ANY_VALUE(session_duration) session_duration,
             CASE WHEN SUM(TollFreeNumber) > 0 THEN 'TollFree' ELSE 'NonTollFree' END TollFreeNumber
      FROM callback_subset
      GROUP BY CallingNumber, SessionId
      )
),


metric_prep AS (
SELECT
       SessionId,
       ActionId,
       TimeStamp,
       ROW_NUMBER() OVER (PARTITION BY SessionId ORDER BY TimeStamp) AS rank_event,
       FIRST_VALUE(TimeStamp) OVER (PARTITION BY SessionId ORDER BY TimeStamp) AS first_timestamp,
       LEAD(TimeStamp) OVER (PARTITION BY SessionId ORDER BY TimeStamp) AS next_timestamp,
       LEAD(ActionId) OVER (PARTITION BY SessionId ORDER BY TimeStamp) AS next_event,
       FlowName,

FROM
filtered
),


Session_paths AS (
SELECT DISTINCT SessionId, TimeStamp, Path
FROM (
    SELECT
      SessionId,
      first_timestamp AS TimeStamp,
      STRING_AGG(ActionId, ';') OVER(PARTITION BY SessionId ORDER BY TimeStamp) AS Path,
      RANK() OVER(PARTITION BY SessionId ORDER BY TimeStamp DESC) AS rank
    FROM
        metric_prep
       )
WHERE rank = 1
),

path_ranks AS (
SELECT *,
      CONCAT(ROW_NUMBER() OVER(), '-Path_Freq_Rank') AS nickname
FROM (
      SELECT
        Path,
        COUNT(TimeStamp) count
      FROM Session_paths
      GROUP BY Path
      ORDER BY count DESC
      )
)


SELECT
       DISTINCT
       m.SessionId AS user_id,
       m.ActionId  AS event_name,
       m.TimeStamp AS time_event,
       CAST(EXTRACT(DATE FROM m.TimeStamp) AS DATETIME) AS date,
       m.rank_event AS rank_event,
       m.next_event AS next_event,
       m.FlowName AS FlowName,
       TIMESTAMP_DIFF(m.TimeStamp, m.first_timestamp, SECOND) AS time_from_start,
       TIMESTAMP_DIFF(m.next_timestamp, m.TimeStamp, SECOND) AS time_to_next,
       pr.nickname AS path_nickname,
       1 AS count,
       cb.CallingNumber,
       cb.rank callback_instance,
       cb.days_since_last_call,
       cb.session_duration,
       cb.previous_duration,
       cb.TollFreeNumber AS TollFreeNumber
FROM metric_prep m
INNER JOIN Session_paths s USING(SessionId)
INNER JOIN path_ranks pr USING(Path)
LEFT JOIN callbacks cb USING(SessionId)
ORDER BY user_id, time_event
