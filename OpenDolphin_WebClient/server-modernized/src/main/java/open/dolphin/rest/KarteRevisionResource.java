package open.dolphin.rest;

import jakarta.inject.Inject;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.WebApplicationException;
import jakarta.ws.rs.core.Context;
import jakarta.ws.rs.core.MediaType;
import java.time.LocalDate;
import java.time.format.DateTimeParseException;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.logging.Level;
import java.util.logging.Logger;
import open.dolphin.infomodel.AttachmentModel;
import open.dolphin.infomodel.DocumentModel;
import open.dolphin.infomodel.IInfoModel;
import open.dolphin.infomodel.SchemaModel;
import open.dolphin.rest.dto.KarteRevisionDiffResponse;
import open.dolphin.rest.dto.KarteRevisionHistoryResponse;
import open.dolphin.security.audit.AuditEventPayload;
import open.dolphin.security.audit.AuditTrailService;
import open.dolphin.session.KarteRevisionServiceBean;
import open.dolphin.session.framework.SessionTraceContext;
import open.dolphin.session.framework.SessionTraceManager;

/**
 * Phase1: read-only append-only revision browsing API for chart documents.
 */
@Path("/karte/revisions")
public class KarteRevisionResource extends AbstractResource {

    private static final Logger LOGGER = Logger.getLogger(KarteRevisionResource.class.getName());

    @Inject
    private KarteRevisionServiceBean karteRevisionServiceBean;

    @Inject
    private AuditTrailService auditTrailService;

    @Inject
    private SessionTraceManager sessionTraceManager;

    @Context
    private HttpServletRequest httpServletRequest;

    @GET
    @Produces(MediaType.APPLICATION_JSON)
    public KarteRevisionHistoryResponse getHistory(@QueryParam("karteId") Long karteId,
                                                   @QueryParam("visitDate") String visitDate,
                                                   @QueryParam("encounterId") String encounterId) {
        // Phase1: prefer visitDate; allow encounterId as alias for compatibility with earlier drafts.
        String effectiveVisitDate = (visitDate != null && !visitDate.isBlank()) ? visitDate : encounterId;

        if (karteId == null || karteId <= 0) {
            throw validationError("REVISION_VALIDATION_ERROR", "karteId is required", Map.of("karteId", karteId));
        }
        LocalDate day = parseLocalDateOrThrow(effectiveVisitDate, "visitDate");

        KarteRevisionHistoryResponse response = karteRevisionServiceBean.getRevisionHistory(karteId, day);
        recordAudit("KARTE_REVISION_HISTORY_READ", Map.of(
                "status", "SUCCESS",
                "karteId", karteId,
                "visitDate", day.toString()
        ));
        return response;
    }

    @GET
    @Path("/{revisionId}")
    @Produces(MediaType.APPLICATION_JSON)
    public DocumentModel getRevision(@PathParam("revisionId") long revisionId) {
        if (revisionId <= 0) {
            throw validationError("REVISION_VALIDATION_ERROR", "revisionId is required",
                    Map.of("revisionId", revisionId));
        }

        DocumentModel doc = karteRevisionServiceBean.getRevisionSnapshot(revisionId);
        if (doc == null) {
            recordAudit("KARTE_REVISION_GET", Map.of(
                    "status", "MISSING",
                    "revisionId", revisionId,
                    "createdRevisionId", revisionId
            ));
            throw restError(httpServletRequest, jakarta.ws.rs.core.Response.Status.NOT_FOUND,
                    "revision_not_found", "Revision not found",
                    Map.of("revisionId", revisionId),
                    null);
        }

        stripHeavyBytes(doc);
        recordAudit("KARTE_REVISION_GET", Map.of(
                "status", "SUCCESS",
                "revisionId", revisionId,
                "createdRevisionId", revisionId
        ));
        return doc;
    }

    @GET
    @Path("/diff")
    @Produces(MediaType.APPLICATION_JSON)
    public KarteRevisionDiffResponse diff(@QueryParam("fromRevisionId") Long fromRevisionId,
                                          @QueryParam("toRevisionId") Long toRevisionId) {
        if (fromRevisionId == null || fromRevisionId <= 0 || toRevisionId == null || toRevisionId <= 0) {
            throw validationError("REVISION_VALIDATION_ERROR",
                    "fromRevisionId/toRevisionId are required",
                    Map.of("fromRevisionId", fromRevisionId, "toRevisionId", toRevisionId));
        }

        KarteRevisionDiffResponse response = karteRevisionServiceBean.diffRevisions(fromRevisionId, toRevisionId);
        if (response == null) {
            recordAudit("KARTE_REVISION_DIFF", Map.of(
                    "status", "MISSING",
                    "fromRevisionId", fromRevisionId,
                    "toRevisionId", toRevisionId,
                    "baseRevisionId", fromRevisionId,
                    "createdRevisionId", toRevisionId
            ));
            throw restError(httpServletRequest, jakarta.ws.rs.core.Response.Status.NOT_FOUND,
                    "revision_not_found", "Revision not found",
                    Map.of("fromRevisionId", fromRevisionId, "toRevisionId", toRevisionId),
                    null);
        }

        recordAudit("KARTE_REVISION_DIFF", Map.of(
                "status", "SUCCESS",
                "fromRevisionId", fromRevisionId,
                "toRevisionId", toRevisionId,
                "baseRevisionId", fromRevisionId,
                "createdRevisionId", toRevisionId
        ));
        return response;
    }

    private void stripHeavyBytes(DocumentModel doc) {
        if (doc == null) {
            return;
        }
        List<AttachmentModel> attachments = doc.getAttachment();
        if (attachments != null) {
            for (AttachmentModel attachment : attachments) {
                if (attachment != null) {
                    attachment.setBytes(null);
                }
            }
        }
        List<SchemaModel> schema = doc.getSchema();
        if (schema != null) {
            for (SchemaModel image : schema) {
                if (image != null) {
                    image.setJpegByte(null);
                }
            }
        }
    }

    private LocalDate parseLocalDateOrThrow(String value, String fieldName) {
        if (value == null || value.isBlank()) {
            throw validationError("REVISION_VALIDATION_ERROR", fieldName + " is required", Map.of(fieldName, value));
        }
        try {
            return LocalDate.parse(value.trim());
        } catch (DateTimeParseException ex) {
            throw validationError("REVISION_VALIDATION_ERROR", fieldName + " must be YYYY-MM-DD",
                    Map.of(fieldName, value));
        }
    }

    private WebApplicationException validationError(String code, String message, Map<String, ?> details) {
        return restError(httpServletRequest, jakarta.ws.rs.core.Response.Status.UNPROCESSABLE_ENTITY, code, message, details,
                null);
    }

    private void recordAudit(String action, Map<String, Object> details) {
        if (auditTrailService == null) {
            return;
        }
        try {
            AuditEventPayload payload = new AuditEventPayload();
            String actorId = resolveActorId();
            payload.setActorId(actorId);
            payload.setActorDisplayName(resolveActorDisplayName(actorId));
            if (httpServletRequest != null && httpServletRequest.isUserInRole("ADMIN")) {
                payload.setActorRole("ADMIN");
            }
            payload.setAction(action);
            payload.setResource(httpServletRequest != null ? httpServletRequest.getRequestURI() : "/karte/revisions");
            String requestId = resolveRequestId();
            String traceId = resolveTraceId(httpServletRequest);
            if (traceId == null || traceId.isBlank()) {
                traceId = requestId;
            }
            payload.setRequestId(requestId);
            payload.setTraceId(traceId);
            payload.setIpAddress(httpServletRequest != null ? httpServletRequest.getRemoteAddr() : null);
            payload.setUserAgent(httpServletRequest != null ? httpServletRequest.getHeader("User-Agent") : null);

            Map<String, Object> enriched = new HashMap<>();
            if (details != null) {
                enriched.putAll(details);
            }
            enrichUserDetails(enriched);
            enrichTraceDetails(enriched);
            // Ensure Phase1 audit container can carry cmd21 alignment fields (append-only tracking).
            enriched.putIfAbsent("sourceRevisionId", null);
            payload.setDetails(enriched);

            auditTrailService.record(payload);
        } catch (Exception ex) {
            LOGGER.log(Level.FINE, "Failed to record revision audit action=" + action, ex);
        }
    }

    private void enrichUserDetails(Map<String, Object> details) {
        String remoteUser = httpServletRequest != null ? httpServletRequest.getRemoteUser() : null;
        if (remoteUser != null) {
            details.put("remoteUser", remoteUser);
            int idx = remoteUser.indexOf(IInfoModel.COMPOSITE_KEY_MAKER);
            if (idx > 0) {
                details.put("facilityId", remoteUser.substring(0, idx));
                if (idx + 1 < remoteUser.length()) {
                    details.put("userId", remoteUser.substring(idx + 1));
                }
            }
        }
    }

    private void enrichTraceDetails(Map<String, Object> details) {
        boolean traceCaptured = false;
        if (sessionTraceManager != null) {
            SessionTraceContext context = sessionTraceManager.current();
            if (context != null) {
                details.put("traceId", context.getTraceId());
                details.put("sessionOperation", context.getOperation());
                traceCaptured = true;
            }
        }
        if (!traceCaptured) {
            String traceId = resolveTraceId(httpServletRequest);
            if (traceId != null) {
                details.put("traceId", traceId);
            }
        }
    }

    private String resolveActorId() {
        return Optional.ofNullable(httpServletRequest != null ? httpServletRequest.getRemoteUser() : null)
                .orElse("system");
    }

    private String resolveActorDisplayName(String actorId) {
        if (actorId == null) {
            return "system";
        }
        int idx = actorId.indexOf(IInfoModel.COMPOSITE_KEY_MAKER);
        if (idx >= 0 && idx + 1 < actorId.length()) {
            return actorId.substring(idx + 1);
        }
        return actorId;
    }

    private String resolveRequestId() {
        if (httpServletRequest == null) {
            return UUID.randomUUID().toString();
        }
        String header = httpServletRequest.getHeader("X-Request-Id");
        if (header != null && !header.isBlank()) {
            return header.trim();
        }
        return UUID.randomUUID().toString();
    }
}
