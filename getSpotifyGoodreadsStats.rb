# this lambda returns:
# 1. top spotify genres based on top tracks for the past one month,
# 2. books from Goodreads currently-reading shelf
require 'json'
require 'httparty'
require 'aws-sdk-secretsmanager'
require 'base64'
require 'date'

def lambda_handler(event:, context:)

  books_secret_name = "secret-1"
  spotify_secret_name = 'secret-2'
  region_name = "some-region-1"
  client = Aws::SecretsManager::Client.new(region: region_name)

  get_goodreads_secret = client.get_secret_value(secret_id: books_secret_name)
  goodreads_secret = JSON.parse(get_goodreads_secret.secret_string)['key']

  get_spotify_secret = client.get_secret_value(secret_id: spotify_secret_name)
  spotify_secret = JSON.parse(get_spotify_secret.secret_string)

  # since Spotify tokens live only 1 hour,
  # we need to check the expiration date and refresh token accordingly.
  if DateTime.parse(spotify_secret['expires_at']) < DateTime.now
    # https://developer.spotify.com/documentation/general/guides/authorization-guide/#authorization-code-flow
    # Spotify requires client_id and secret encoded in base64 in headers.
    auth_64 = Base64.strict_encode64("#{spotify_secret['client_id']}:#{spotify_secret['client_secret']}")
    options = {
      body: {
        refresh_token: spotify_secret['refresh_token'],
        grant_type: 'refresh_token'
      },
      headers: {
        'Content-Type' => 'application/x-www-form-urlencoded',
        'Authorization' => "Basic #{auth_64}"
      }
    }
    spotify_refresh_response = HTTParty.post('https://accounts.spotify.com/api/token', options).parsed_response

    # Updating secret hash with  expiration date 1 hour from now and new access token
    spotify_secret.update({ expires_at: (DateTime.now + 1.0 / 24).to_s, access_token: spotify_refresh_response['access_token'] })
    # Updating actual secret with a secret hash
    client.update_secret({ secret_id: spotify_secret_name, secret_string: spotify_secret.to_json })

    spotify_secret['access_token'] = spotify_refresh_response['access_token']

  end

  top_tracks = HTTParty.get("https://api.spotify.com/v1/me/top/tracks?time_range=short_term&limit=50",
    { headers: { 'Authorization' => "Bearer #{spotify_secret['access_token']}" } }).parsed_response

  artist_ids_arr = []
  # maximum number of artists we can get from spotify is 50, since some tracks can have more than one artists,
  # we check length of artist_ids_arr prior to pushing
  top_tracks['items'].each { |t| t['artists'].each { |a| artist_ids_arr.push(a['id']) if artist_ids_arr.length < 50 } }

  # join artist ids to string separated by ","
  artist_ids = artist_ids_arr.join(',')

  artists = HTTParty.get("https://api.spotify.com/v1/artists?ids=#{artist_ids}",
    { headers: { 'Authorization' => "Bearer #{spotify_secret['access_token']}" } }).parsed_response

  genres = []
  artists['artists'].each { |a| a['genres'].each { |g| genres.push(g) } }

  # calculate frequency of each genre in array
  genres_weighted = genres.tally
  # remove genre is frequency is less than 4
  genres_weighted.delete_if { |k, v| v <= 3 }
  # genre with max frequency is 100% value
  one_hun_value = genres_weighted.values.max
  # calculate frequency of each genre related to the most frequent genre in percents
  music_response = genres_weighted.map { |k, v| { value: "#{k}", count: (100 * v) / one_hun_value } }

  books = HTTParty.get("https://www.goodreads.com/review/list?v=2&id=26737737&key=#{goodreads_secret}&shelf=currently-reading").parsed_response['GoodreadsResponse']['reviews']
  books_response = []

  # Goodreads returns multiple books in array, but single book in a hash
  if books['total'] == '1'
    book = books['review']['book']
    title = book['title']
    author = book['authors']['author']["name"]
    img = book['small_image_url']
    url = book['link']
    books_response.push({ "title": title, "author": author, "img": img, "url": url })

  elsif books['total'] > '1'
    books.each do |b|
      book = b['review']
      title = book['book']['title']
      author = book['book']['authors']['author']["name"]
      img = book['small_image_url']
      url = book['book']['link']
      books_response.push({ "title": title, "author": author, "img": img, "url": url })
    end
  end

  { statusCode: 200, body: { books: books_response, music: music_response } }

end

# example of response:
# {
#     "statusCode": 200,
#     "body": {
#         "books": [
#             {
#                 "title": "Those Are Real Bullets: Bloody Sunday, Derry, 1972",
#                 "author": "Peter Pringle",
#                 "img": "https://s.gr-assets.com/assets/nophoto/book/50x75-a91bf249278a81aabab721ef782c4a74.png",
#                 "url": "https://www.goodreads.com/book/show/1045536.Those_Are_Real_Bullets"
#             }
#         ],
#         "music": [
#             {
#                 "value": "icelandic electronic",
#                 "count": 100
#             },
#             {
#                 "value": "icelandic rock",
#                 "count": 100
#             },
#             {
#                 "value": "alternative metal",
#                 "count": 94
#             },
#             {
#                 "value": "industrial metal",
#                 "count": 83
#             },
#             {
#                 "value": "industrial rock",
#                 "count": 77
#             },
#             {
#                 "value": "nu metal",
#                 "count": 83
#             },
#             {
#                 "value": "german metal",
#                 "count": 44
#             },
#             {
#                 "value": "industrial",
#                 "count": 61
#             },
#             {
#                 "value": "neue deutsche harte",
#                 "count": 55
#             }
#         ]
#     }
# }
