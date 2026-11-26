//
//  WebRoutes.swift
//  DeFeedbackHost
//
//  The web API's route table: which path answers which methods, and what a wrong method is told.
//  Every path here must be documented in openapi.yaml and vice versa (OpenAPIConformanceTests
//  reads this file to check). One path, `/api/instances/{id}`, is matched by template first.
//  Replaces the long `switch` that lived in WebControlService (issue #41); behaviour is unchanged.
//
import Foundation

enum WebRoutes {

    /// Handles a request: the service, the request, and the `{id}` of the instance template (else nil).
    typealias Handler = @MainActor @Sendable (WebControlService, HTTPRequest, String?) async -> HTTPServer.RouteOutcome

    struct Route {
        let handlers: [String: Handler]

        /// What a method that has no handler is told (405) and which methods the `Allow` header lists.
        let wrongMethod: WebErrorStrings
        let allow: String

        @MainActor
        func answer(_ request: HTTPRequest, from service: WebControlService, id: String?) async -> HTTPServer.RouteOutcome {
            guard let handler = handlers[request.method] else {
                return .respond(.error(405, wrongMethod.rawValue, headers: [("Allow", allow)]))
            }
            return await handler(service, request, id)
        }
    }

    /// The one route matched by template rather than whole path. Checked before `table`.
    static let instanceTemplate = "/api/instances/{id}"

    static let instance = Route(
        handlers: [
            "GET": respond { service, _, id in service.instanceResponse(id: id ?? "") },
            "HEAD": respond { service, _, id in service.instanceResponse(id: id ?? "") },
            "PATCH": respond { service, request, id in await service.updateInstance(id: id ?? "", request) },
            "DELETE": respond { service, _, id in service.removeInstance(id: id ?? "") },
        ],
        wrongMethod: .UseInstanceMethod, allow: "GET, HEAD, PATCH, DELETE")

    private static let page = respond { service, _, _ in service.pageResponse() }
    private static let status = respond { service, _, _ in .json(service.statusPayload()) }
    private static let update = respond { service, _, _ in .json(service.updatePayload()) }
    private static let list = respond { service, _, _ in .json(WebStatusPayload.instanceList(service.host.instances)) }
    private static let events: Handler = { service, _, _ in
        .stream(EventStream.preamble) { [weak service] stream in
            guard let service else { return }
            Task { @MainActor in
                service.attachStream(stream)
            }
        }
    }

    /// Whole-path routes. A path that is not here is a 404.
    static let table: [String: Route] = [
        "/": Route(handlers: ["GET": page, "HEAD": page], wrongMethod: .UseGET, allow: "GET, HEAD"),
        // HEAD is listed in `Allow` but not served here; kept as it was (see implementation-notes.md).
        "/index.html": Route(handlers: ["GET": page], wrongMethod: .UseGET, allow: "GET, HEAD"),
        "/api/status": Route(handlers: ["GET": status, "HEAD": status], wrongMethod: .UseGET, allow: "GET, HEAD"),
        "/api/update": Route(handlers: ["GET": update, "HEAD": update], wrongMethod: .UseGET, allow: "GET, HEAD"),
        "/api/instances": Route(
            handlers: ["GET": list, "HEAD": list,
                       "POST": respond { service, request, _ in await service.addInstance(request) }],
            wrongMethod: .UseGETorPOST, allow: "GET, HEAD, POST"),
        "/api/events": Route(handlers: ["GET": events], wrongMethod: .UseGET, allow: "GET"),
        "/api/system": post { service, request in await service.controlSystem(request) },
        "/api/devices": post { service, request in await service.setDevices(request) },
        "/api/sample-rate": post { service, request in await service.setSampleRate(request) },
        "/api/buffer-size": post { service, request in await service.setBufferSize(request) },
    ]

    /// A handler that answers with a plain response.
    private static func respond(
        _ work: @escaping @MainActor @Sendable (WebControlService, HTTPRequest, String?) async -> HTTPResponse
    ) -> Handler {
        { service, request, id in .respond(await work(service, request, id)) }
    }

    /// A POST-only command route.
    private static func post(
        _ work: @escaping @MainActor @Sendable (WebControlService, HTTPRequest) async -> HTTPResponse
    ) -> Route {
        Route(handlers: ["POST": respond { service, request, _ in await work(service, request) }],
              wrongMethod: .UsePOST, allow: "POST")
    }
}
