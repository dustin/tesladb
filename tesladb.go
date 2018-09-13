package main

import (
	"context"
	"encoding/json"
	"flag"
	"log"
	"net/http"
	"time"

	couch "github.com/dustin/go-couch"
	"github.com/dustin/httputil"
	"golang.org/x/sync/errgroup"
)

const (
	userAgent = "Mozilla/5.0 (Linux; Android 9.0.0; VS985 4G Build/LRX21Y; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/58.0.3029.83 Mobile Safari/537.36"
	teslaUA   = "TeslaApp/3.4.4-350/fad4a582e/android/9.0.0"

	urlBase = "https://owner-api.teslamotors.com/api/1/vehicles/"
)

var (
	bearer   = flag.String("bearer", "", "auth bearer token")
	vid      = flag.String("vid", "", "vehicle ID")
	period   = flag.Duration("period", time.Minute*10, "update period")
	couchURL = flag.String("couch", "http://localhost:5984/tesla", "couch db url")
)

func getTeslaURL(ctx context.Context, u string, o interface{}) error {
	req, err := http.NewRequest("GET", u, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+*bearer)
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("X-Tesla-User-Agent", teslaUA)

	req = req.WithContext(ctx)

	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return httputil.HTTPError(res)
	}

	return json.NewDecoder(res.Body).Decode(o)
}

type StateRecord struct {
	Type   string           `json:"type"`
	Charge *json.RawMessage `json:"charge"`
	Drive  *json.RawMessage `json:"drive"`
}

func storeData(ctx context.Context, db *couch.Database, st *StateRecord) error {
	did := "state_" + time.Now().Format("20060102150405Z")
	_, _, err := db.InsertWith(st, did)
	return err
}

type Response struct {
	Response *json.RawMessage
}

func update(ctx context.Context, db *couch.Database) error {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()

	g := errgroup.Group{}

	st := &StateRecord{Type: "state"}

	g.Go(func() error {
		r := &Response{}
		if err := getTeslaURL(ctx,
			urlBase+*vid+"/data_request/charge_state", r); err != nil {
			return err
		}
		st.Charge = r.Response
		return nil
	})

	g.Go(func() error {
		r := &Response{}
		if err := getTeslaURL(ctx,
			urlBase+*vid+"/data_request/drive_state", r); err != nil {
			return err
		}

		st.Drive = r.Response
		return nil
	})

	if err := g.Wait(); err != nil {
		return err
	}

	return storeData(ctx, db, st)
}

func main() {
	flag.Parse()

	ctx := context.Background()

	db, err := couch.Connect(*couchURL)
	if err != nil {
		log.Fatalf("Can't connect to DB: %v", err)
	}

	if err := update(ctx, &db); err != nil {
		log.Fatalf("Error on first run: %v", err)
	}
	for range time.Tick(*period) {
		if err := update(ctx, &db); err != nil {
			log.Printf("Error updating: %v", err)
		}
	}
}
